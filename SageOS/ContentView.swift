//
//  ContentView.swift
//  SageOS
//

import SwiftUI

/// Invisible persistent launcher. SplineRuntime exposes no scene-reload API,
/// so the only way "Start new session" can actually reset the demo back to
/// `hello` is by dismissing and reopening the entire ImmersiveSpace — which
/// requires a long-lived SwiftUI view to hold the `openImmersiveSpace` /
/// `dismissImmersiveSpace` environment actions. We keep this window alive
/// for the whole app launch but render it as a single transparent pixel
/// with no glass backing, so a participant in mixed immersion barely sees
/// anything in their peripheral vision.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase)   private var scenePhase
    @Environment(\.openImmersiveSpace)    private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                Task {
                    await appModel.preloadScenes()
                    appModel.setupControlServer()
                    // Auto-start so the demo runs even if the laptop control
                    // page never connects (Wi-Fi/hotspot flakiness). The
                    // operator can still End / Start new session from the
                    // laptop dashboard — those overwrite this auto-started
                    // session.
                    await appModel.startNewSession()
                }
            }
            .onChange(of: appModel.shouldOpenImmersive) { _, shouldOpen in
                Task {
                    if shouldOpen {
                        _ = await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    } else {
                        await dismissImmersiveSpace()
                    }
                }
            }
            // When the AVP wakes from an off-head sleep, scenePhase flips
            // back to .active. Re-assert the control server immediately so
            // the laptop dashboard reconnects without lag.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appModel.ensureControlAlive()
                }
            }
    }
}
