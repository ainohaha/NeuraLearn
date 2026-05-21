//
//  GazeSession.swift
//  SageOS
//
//  Head-pose gaze-proxy tracker. Apple does not expose raw eye-gaze to
//  third-party apps, so this samples the device (head) forward vector via
//  ARKit's WorldTrackingProvider and treats it as an attention signal.
//  Output is a JSON log of (yaw, pitch, scene, t) tuples in Documents.
//
//  Robustness notes:
//   * `start()` explicitly requests `.worldSensing` authorization before
//     running the session, and refuses to proceed if denied.
//   * A separate task watches `session.events` for DataProviderStateChanged,
//     so we can see in the console whether the provider is actually `.running`,
//     `.initialized`, `.paused`, or `.stopped` at any moment.
//   * The poll loop runs on a detached high-priority Task — not on MainActor —
//     because `queryDeviceAnchor` is expected to be called from a render-thread
//     style cadence; we hop back to MainActor only to mutate observable state.
//   * The JSON is checkpoint-written every 3 seconds, so if the app is killed
//     mid-session (participant takes off the headset, force-quits, etc.) the
//     last checkpoint is still on disk.
//

import ARKit
import Foundation
import QuartzCore
import simd

@MainActor
@Observable
final class GazeSession {

    // MARK: - Public state

    private(set) var isRecording = false
    private(set) var lastError: String?
    private(set) var sampleCount = 0
    private(set) var lastLogURL: URL?

    /// Most recent sample. Updated on every poll tick so debug UI can observe.
    private(set) var lastSample: Sample?

    /// Live state of the WorldTrackingProvider, mirrored from session events.
    /// Watch this in the debug window if samples stop arriving.
    private(set) var providerState: String = "not-started"

    /// Rolling window of the most recent samples (newest at the end).
    /// Cleared on `markScene` so the debug trail only shows the current scene.
    /// Sized for ~3s of trail at the default 30 Hz sample rate.
    private(set) var recentSamples: [Sample] = []
    private let recentCapacity = 90

    // MARK: - Tunables

    /// Polling cadence. 30 Hz is plenty for attention heatmaps; higher just adds
    /// micro-tremor noise.
    var sampleHz: Double = 30

    /// Interval between JSON checkpoint writes while recording. Smaller =
    /// less data lost on crash, more disk churn.
    var checkpointInterval: TimeInterval = 3.0

    // MARK: - Data model

    struct Sample: Codable {
        let t: Double      // seconds since session start (monotonic)
        let yaw: Float     // radians, 0 = forward, +right
        let pitch: Float   // radians, +up
        let scene: String
    }

    struct SceneSpan: Codable {
        let id: String
        let start: Double
        var end: Double?
    }

    struct Log: Codable {
        let sessionID: String
        let startedAt: Double        // UTC seconds since 1970
        let durationSeconds: Double
        let device: String
        let scenes: [SceneSpan]
        let samples: [Sample]
    }

    // MARK: - Internals

    private let session = ARKitSession()
    /// Recreated on every `start()` because `WorldTrackingProvider` cannot be
    /// reused after the session that ran it was stopped.
    private var worldTracking = WorldTrackingProvider()
    private var samples: [Sample] = []
    private var sceneSpans: [SceneSpan] = []
    private var startMonotonic: CFTimeInterval = 0
    private var startedAtUTC: Double = 0
    private var currentScene: String = "unknown"
    private var sessionID = UUID().uuidString
    private var pollTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() async {
        guard !isRecording else { return }
        guard WorldTrackingProvider.isSupported else {
            lastError = "WorldTrackingProvider not supported on this device"
            print("[GazeSession] \(lastError ?? "")")
            return
        }

        // Explicit authorization request. Without this the provider may
        // succeed at `run` but never reach `.running`, which produces the
        // "The device_anchor can only be queried when the world tracking
        // provider is running" error we saw in the first capture.
        let auth = await session.requestAuthorization(for: [.worldSensing])
        if auth[.worldSensing] != .allowed {
            lastError = "world sensing not allowed: \(String(describing: auth[.worldSensing]))"
            print("[GazeSession] \(lastError ?? "")")
            return
        }

        worldTracking = WorldTrackingProvider()
        do {
            try await session.run([worldTracking])
        } catch {
            lastError = "ARKitSession.run failed: \(error.localizedDescription)"
            print("[GazeSession] \(lastError ?? "")")
            return
        }

        samples.removeAll(keepingCapacity: true)
        sceneSpans.removeAll(keepingCapacity: true)
        sampleCount = 0
        lastError = nil
        sessionID = UUID().uuidString
        startMonotonic = CACurrentMediaTime()
        startedAtUTC = Date().timeIntervalSince1970
        isRecording = true
        providerState = "starting"

        // Capture immutable handles for the detached poll task so we don't
        // touch MainActor state from off-actor.
        let provider = worldTracking
        let started = startMonotonic
        let hz = sampleHz

        eventsTask = Task { [weak self] in
            await self?.monitorEvents()
        }

        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.pollLoop(provider: provider, started: started, hz: hz)
        }

        checkpointTask = Task { [weak self] in
            await self?.checkpointLoop()
        }

        print("[GazeSession] started — session \(sessionID)")
    }

    @discardableResult
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        pollTask?.cancel()
        eventsTask?.cancel()
        checkpointTask?.cancel()
        pollTask = nil
        eventsTask = nil
        checkpointTask = nil
        session.stop()

        let elapsed = CACurrentMediaTime() - startMonotonic
        if let lastIdx = sceneSpans.indices.last, sceneSpans[lastIdx].end == nil {
            sceneSpans[lastIdx].end = elapsed
        }

        let url = writeJSON(durationSeconds: elapsed, label: "final")
        lastLogURL = url
        return url
    }

    /// Tag subsequent samples with a new scene id. Closes the previous span.
    /// Clears the in-memory `recentSamples` trail so the debug overlay restarts
    /// from empty for the new scene — the on-disk log still contains every sample.
    func markScene(_ id: String) {
        currentScene = id
        recentSamples.removeAll(keepingCapacity: true)
        guard isRecording else { return }
        let now = CACurrentMediaTime() - startMonotonic
        if let lastIdx = sceneSpans.indices.last, sceneSpans[lastIdx].end == nil {
            sceneSpans[lastIdx].end = now
        }
        sceneSpans.append(SceneSpan(id: id, start: now, end: nil))
    }

    // MARK: - Sampling (off-MainActor)

    nonisolated private func pollLoop(
        provider: WorldTrackingProvider,
        started: CFTimeInterval,
        hz: Double
    ) async {
        let intervalNanos = UInt64(1_000_000_000.0 / hz)
        var nilCount = 0
        var totalTicks = 0
        while !Task.isCancelled {
            totalTicks += 1
            if let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                let m = anchor.originFromAnchorTransform
                let fx = -m.columns.2.x
                let fy = -m.columns.2.y
                let fz = -m.columns.2.z
                let yaw = atan2(fx, -fz)
                let pitch = asin(max(-1, min(1, fy)))
                let elapsed = CACurrentMediaTime() - started
                let sample = Sample(t: elapsed, yaw: yaw, pitch: pitch, scene: "")
                await self.ingestSample(sample)
            } else {
                nilCount += 1
                // Log every ~3s of nil to avoid spam but surface persistent failures.
                if nilCount % Int(hz * 3) == 0 {
                    let pct = Double(nilCount) / Double(totalTicks) * 100
                    print("[GazeSession] queryDeviceAnchor nil — \(nilCount)/\(totalTicks) ticks (\(String(format: "%.0f", pct))%)")
                }
            }
            try? await Task.sleep(nanoseconds: intervalNanos)
        }
    }

    private func ingestSample(_ raw: Sample) {
        guard isRecording else { return }
        let sample = Sample(t: raw.t, yaw: raw.yaw, pitch: raw.pitch, scene: currentScene)
        samples.append(sample)
        sampleCount = samples.count
        lastSample = sample
        recentSamples.append(sample)
        if recentSamples.count > recentCapacity {
            recentSamples.removeFirst(recentSamples.count - recentCapacity)
        }
    }

    // MARK: - Provider state monitor

    private func monitorEvents() async {
        for await event in session.events {
            switch event {
            case .dataProviderStateChanged(let providers, let newState, let error):
                let names = providers.map { String(describing: type(of: $0)) }.joined(separator: ",")
                let stateStr = String(describing: newState)
                providerState = stateStr
                if let error {
                    print("[GazeSession] provider state: \(stateStr) (\(names)) — error: \(error)")
                } else {
                    print("[GazeSession] provider state: \(stateStr) (\(names))")
                }
            case .authorizationChanged(let type, let status):
                print("[GazeSession] auth changed: \(type) → \(status)")
            default:
                break
            }
            if Task.isCancelled { break }
        }
    }

    // MARK: - Checkpointing

    private func checkpointLoop() async {
        while !Task.isCancelled, isRecording {
            try? await Task.sleep(for: .seconds(checkpointInterval))
            guard isRecording, !Task.isCancelled else { break }
            let elapsed = CACurrentMediaTime() - startMonotonic
            _ = writeJSON(durationSeconds: elapsed, label: "checkpoint")
        }
    }

    // MARK: - I/O

    @discardableResult
    private func writeJSON(durationSeconds: TimeInterval, label: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        // Stable per-session filename — checkpoints overwrite the same file.
        let filename = "gaze-\(Int(startedAtUTC)).json"
        let url = docs.appendingPathComponent(filename)
        let log = Log(
            sessionID: sessionID,
            startedAt: startedAtUTC,
            durationSeconds: durationSeconds,
            device: "Apple Vision Pro",
            scenes: sceneSpans,
            samples: samples
        )
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(log).write(to: url, options: .atomic)
            print("[GazeSession] \(label) wrote \(url.lastPathComponent) — \(samples.count) samples over \(String(format: "%.1f", durationSeconds))s")
            return url
        } catch {
            print("[GazeSession] write failed: \(error)")
            lastError = "write failed: \(error.localizedDescription)"
            return nil
        }
    }
}
