//
//  AppModel.swift
//  SageOS
//
//  Created by Aino Halonen on 4/3/26.
//

import QuartzCore
import SwiftUI

struct SageScene: Identifiable {
    let id: String
    /// `nil` = button-gated: the Spline scene shows a button/gate and we wait
    /// forever until `AppModel.advance()` is called by the operator pressing
    /// Next on the laptop dashboard. Non-nil = timed (unused at present).
    let duration: TimeInterval?
}

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"

    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // All "scenes" below are internal Spline states inside a single published
    // file. Their ids stamp every gaze sample in the JSON log — keep them
    // aligned with the Spline state names so the heatmap tooling labels
    // things correctly.
    //
    // Every scene is button-gated: the participant watches the demo and
    // clicks Spline buttons (or just lets timed Spline transitions play),
    // while the operator watches the mirror on the Mac and presses
    // <space> on the control page (http://<headset-ip>:9876) at each
    // visible transition. That keystroke stamps the new scene id onto
    // subsequent gaze samples.
    static let scenes: [SageScene] = [
        SageScene(id: "hello",               duration: nil),
        SageScene(id: "what-would-you-like", duration: nil),
        SageScene(id: "assignment",          duration: nil),
        SageScene(id: "assignment-2",        duration: nil),
        SageScene(id: "assignment-3",        duration: nil),
        SageScene(id: "ask",                 duration: nil),
        SageScene(id: "adjust",              duration: nil),
        SageScene(id: "begin",               duration: nil),
        SageScene(id: "adjusted-intro",      duration: nil),
        SageScene(id: "adjusted-immersive",  duration: nil),
        SageScene(id: "end",                 duration: nil),
    ]

    private static let splineBase = "https://build.spline.design/GHUXNEykQsZGOnNwvOlk/scene.splineswift"

    // Append a per-launch timestamp so CDN/URLCache can't serve a stale publish.
    private static func cloudSceneURL(_ string: String) -> URL {
        var components = URLComponents(string: string)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url!
    }

    /// Per-session URL with a fresh cache-buster appended. Generating a new
    /// one on each `startNewSession()` and feeding it to `ImmersiveView`
    /// forces SplineRuntime to reload the scene from scratch — without this
    /// the runtime caches the scene and "Start new session" just dismisses
    /// + re-presents the same already-played state machine, so the demo
    /// doesn't actually restart from `hello`.
    private(set) var sessionURL: URL = AppModel.cloudSceneURL(splineBase)

    private func refreshSessionURL() {
        var c = URLComponents(string: Self.splineBase)!
        var items = c.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
        // UUID is the actual cache-buster — same-second restarts still differ.
        items.append(URLQueryItem(name: "n", value: UUID().uuidString))
        c.queryItems = items
        sessionURL = c.url!
    }

    var sceneIndex: Int = 0
    var currentScene: SageScene { Self.scenes[sceneIndex] }

    /// True when the immersive Spline space should be presented. ContentView
    /// observes this and calls `openImmersiveSpace` / `dismissImmersiveSpace`.
    /// Starts `false` so the operator can set up the laptop control page
    /// before the participant sees anything.
    var shouldOpenImmersive = false

    /// Kept only as a flag for any legacy callers; the in-headset debug
    /// window has been removed entirely. All live monitoring (sample count,
    /// yaw/pitch, trail, scene, recording state) is on the laptop control
    /// page — the participant in Guest Mode sees only the immersive scene.
    var debugLiveOverlay = false

    /// Background watchdog that pings the control server every few seconds
    /// so it self-heals after the AVP wakes from an off-head suspend.
    /// `AdvanceServer.start()` is idempotent — a no-op when healthy, a
    /// rebind when the OS cancelled the listener while the app was asleep.
    private var serverWatchdog: Task<Void, Never>?

    let gaze = GazeSession()

    /// HTTP control surface for the researcher's laptop. Started in `runFlow`,
    /// hands every POST /advance through to `advance()`. The server is
    /// non-isolated; it pushes URL/running state back here through callbacks
    /// so SwiftUI can observe via `AppModel`.
    let advanceServer = AdvanceServer()

    /// URL the researcher's laptop should open. Populated by the advance
    /// server once it binds successfully.
    private(set) var advanceServerURL: String?
    private(set) var advanceServerRunning = false

    /// Count of sessions that have been ended this app launch. Useful for
    /// labeling the JSON files and for the control page UI.
    private(set) var sessionsRecorded = 0

    func preloadScenes() async {
        var request = URLRequest(url: sessionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Wire the laptop control server to AppModel and start it. Called once
    /// from ContentView after the immersive space is up; the server stays
    /// running for the rest of the app launch so the researcher can run
    /// many participants without rebuilding.
    func setupControlServer() {
        advanceServer.onAdvance = { [weak self] in self?.advance() }
        advanceServer.onStartSession = { [weak self] in
            Task { await self?.startNewSession() }
        }
        advanceServer.onEndSession = { [weak self] in
            Task { _ = await self?.endSession() }
        }
        advanceServer.stateProvider = { [weak self] () -> AdvanceServer.StateSnapshot in
            guard let self else { return .empty }
            let scene = Self.scenes[self.sceneIndex]
            let last = self.gaze.lastSample
            let agoMs: Int
            if let lastT = self.gaze.lastSampleMonotonic {
                agoMs = max(0, Int((QuartzCore.CACurrentMediaTime() - lastT) * 1000))
            } else {
                agoMs = -1
            }
            // Last ~1s of trail at 30Hz. Kept small so the /state payload
            // stays under ~600 B and we don't tax the AVP serializing on
            // every poll — heavier traffic was visibly hurting the AirPlay
            // mirror's frame rate.
            let trail = self.gaze.recentSamples.suffix(30).map {
                AdvanceServer.TrailPoint(y: $0.yaw, p: $0.pitch)
            }
            return AdvanceServer.StateSnapshot(
                scene: scene.id,
                index: self.sceneIndex,
                total: Self.scenes.count,
                gate: "button",
                samples: self.gaze.sampleCount,
                recording: self.gaze.isRecording,
                sessionsRecorded: self.sessionsRecorded,
                yaw: last?.yaw ?? 0,
                pitch: last?.pitch ?? 0,
                lastSampleAgoMs: agoMs,
                providerState: self.gaze.providerState,
                trail: Array(trail)
            )
        }
        advanceServer.onURLChange = { [weak self] url in
            self?.advanceServerURL = url
        }
        advanceServer.onRunningChange = { [weak self] running in
            self?.advanceServerRunning = running
        }
        advanceServer.start()
        startServerWatchdog()
    }

    /// Idempotent: keeps a ticker alive that re-asserts the control server
    /// every 3 seconds. When the AVP comes off-head and the app suspends, the
    /// OS cancels our NWListener; when the next participant puts the headset
    /// back on, this watchdog ensures the listener is bound again within a
    /// few seconds, so the laptop control page can reach us without anyone
    /// having to relaunch anything.
    func startServerWatchdog() {
        serverWatchdog?.cancel()
        serverWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.advanceServer.start()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Called from the SwiftUI scenePhase observer when the app returns to
    /// active. Cheap: the server's `start()` is idempotent. Also gives the
    /// watchdog an immediate tick so we don't wait up to 3s after waking.
    func ensureControlAlive() {
        advanceServer.start()
    }

    /// Start a fresh recording session. Closes any existing immersive space
    /// first so Spline reloads from its initial state — that way participant
    /// N doesn't inherit the scene state from participant N-1. Then opens
    /// the immersive space, waits for it to present, and begins the gaze
    /// tracker tagged with scene 0.
    func startNewSession() async {
        if gaze.isRecording {
            _ = await gaze.stop()
            sessionsRecorded += 1
        }

        // SplineRuntime exposes no reload API and ignores a sceneFileURL
        // prop change once a scene is loaded — the ONLY way to reset the
        // demo back to `hello` is to dismiss the entire ImmersiveSpace and
        // open it again with a fresh URL. We toggle `shouldOpenImmersive`
        // false→true and ContentView's onChange handler does the actual
        // dismiss/open. The fresh UUID cache-buster on the URL ensures
        // Spline re-fetches from scratch on reopen instead of replaying
        // any cached state machine from participant N-1.
        if shouldOpenImmersive {
            shouldOpenImmersive = false
            try? await Task.sleep(for: .milliseconds(700))
        }
        refreshSessionURL()
        sceneIndex = 0
        shouldOpenImmersive = true
        try? await Task.sleep(for: .seconds(1.5))

        await gaze.start()
        gaze.markScene(Self.scenes[0].id)
        print("[AppModel] session started — scene 1/\(Self.scenes.count): \(Self.scenes[0].id)")
    }

    /// Stop the current recording session, flush its JSON, and dismiss the
    /// immersive space so the next participant sees a clean slate when you
    /// hit Start. The 2D operator window stays visible the whole time.
    /// End the recording but LEAVE the immersive scene running. The next
    /// participant putting on the headset still sees content immediately;
    /// the operator presses "Start new session" when they're ready to begin
    /// the next clean recording (which is what resets Spline to `hello`).
    @discardableResult
    func endSession() async -> URL? {
        let url: URL?
        if gaze.isRecording {
            url = await gaze.stop()
            sessionsRecorded += 1
        } else {
            url = nil
        }
        print("[AppModel] session ended — \(sessionsRecorded) total this run")
        return url
    }

    /// Advance the scene tag by one. Called via the control page's Next
    /// button (or spacebar) each time the operator sees the participant
    /// transition through a Spline scene. No-op if not recording, or if
    /// already on the last scene.
    func advance() {
        guard gaze.isRecording else { return }
        let next = sceneIndex + 1
        guard next < Self.scenes.count else { return }
        sceneIndex = next
        gaze.markScene(Self.scenes[next].id)
    }
}
