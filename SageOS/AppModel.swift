//
//  AppModel.swift
//  SageOS
//
//  Created by Aino Halonen on 4/3/26.
//

import SwiftUI

struct SageScene: Identifiable {
    let id: String
    let url: URL
    /// `nil` = button-gated: the Spline scene shows a button/gate and we wait
    /// forever until `AppModel.advance()` is called (from the debug window now,
    /// from a Spline event hook later). Non-nil = timed: the flow auto-advances
    /// after this many seconds, but `advance()` can still cut it short.
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
    private static let splineURL = AppModel.cloudSceneURL(
        "https://build.spline.design/GHUXNEykQsZGOnNwvOlk/scene.splineswift")

    static let scenes: [SageScene] = [
        SageScene(id: "hello",               url: splineURL, duration: nil),
        SageScene(id: "what-would-you-like", url: splineURL, duration: nil),
        SageScene(id: "assignment",          url: splineURL, duration: nil),
        SageScene(id: "assignment-2",        url: splineURL, duration: nil),
        SageScene(id: "assignment-3",        url: splineURL, duration: nil),
        SageScene(id: "ask",                 url: splineURL, duration: nil),
        SageScene(id: "adjust",              url: splineURL, duration: nil),
        SageScene(id: "begin",               url: splineURL, duration: nil),
        SageScene(id: "adjusted-intro",      url: splineURL, duration: nil),
        SageScene(id: "adjusted-immersive",  url: splineURL, duration: nil),
        SageScene(id: "end",                 url: splineURL, duration: nil),
    ]

    // Append a per-launch timestamp so CDN/URLCache can't serve a stale publish.
    private static func cloudSceneURL(_ string: String) -> URL {
        var components = URLComponents(string: string)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url!
    }

    var sceneIndex: Int = 0
    var currentScene: SageScene { Self.scenes[sceneIndex] }

    /// True when the immersive Spline space should be presented. ContentView
    /// observes this and calls `openImmersiveSpace` / `dismissImmersiveSpace`.
    /// Starts `false` so the operator can set up the laptop control page
    /// before the participant sees anything.
    var shouldOpenImmersive = false

    /// Flip to `true` during development to open a 2D debug window that shows
    /// live gaze yaw/pitch, sample count, current scene name, the most-recent
    /// trail, and a "Next scene" button. Leave `false` before handing the
    /// headset to a participant — the participant should not see this.
    var debugLiveOverlay = true

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
        let urls = Self.scenes.map(\.url)
        for url in urls {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            _ = try? await URLSession.shared.data(for: request)
        }
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
            return AdvanceServer.StateSnapshot(
                scene: scene.id,
                index: self.sceneIndex,
                total: Self.scenes.count,
                gate: "button",
                samples: self.gaze.sampleCount,
                recording: self.gaze.isRecording,
                sessionsRecorded: self.sessionsRecorded
            )
        }
        advanceServer.onURLChange = { [weak self] url in
            self?.advanceServerURL = url
        }
        advanceServer.onRunningChange = { [weak self] running in
            self?.advanceServerRunning = running
        }
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

        // Close and reopen the immersive space so SplineImmersiveSpaceContent
        // is torn down and rebuilt from scratch. Without this, Spline keeps
        // whatever internal state the last participant left it in.
        if shouldOpenImmersive {
            shouldOpenImmersive = false
            try? await Task.sleep(for: .milliseconds(700))
        }
        sceneIndex = 0
        shouldOpenImmersive = true
        // Give the immersive space + Spline a moment to load before we start
        // counting samples, so the first sample isn't tagged before the
        // participant sees anything.
        try? await Task.sleep(for: .seconds(1.5))

        await gaze.start()
        gaze.markScene(Self.scenes[0].id)
        print("[AppModel] session started — scene 1/\(Self.scenes.count): \(Self.scenes[0].id)")
    }

    /// Stop the current recording session, flush its JSON, and dismiss the
    /// immersive space so the next participant sees a clean slate when you
    /// hit Start. The 2D operator window stays visible the whole time.
    @discardableResult
    func endSession() async -> URL? {
        let url: URL?
        if gaze.isRecording {
            url = await gaze.stop()
            sessionsRecorded += 1
        } else {
            url = nil
        }
        shouldOpenImmersive = false
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
