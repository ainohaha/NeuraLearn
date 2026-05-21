//
//  ContentView.swift
//  SageOS
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SageOS")
                .font(.system(size: 44, weight: .bold))
            Text("Gaze-tracking research probe")
                .font(.title3)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 6)

            if let url = appModel.advanceServerURL {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Open the control page on your Mac:")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recommended — works on any Wi-Fi:")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                        Text("python3 /Users/aikoh/Documents/SageOS/tools/watch_and_open.py")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Or, on home/hotspot Wi-Fi, paste in Safari:")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                        Text(url)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Server starting…")
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(appModel.gaze.isRecording ? "● recording session" : "○ waiting for Start")
                    .font(.title3)
                    .foregroundStyle(appModel.gaze.isRecording ? .green : .secondary)
                Text("\(appModel.sessionsRecorded) session\(appModel.sessionsRecorded == 1 ? "" : "s") recorded this run")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            Task {
                await appModel.preloadScenes()
                if appModel.debugLiveOverlay {
                    openWindow(id: "gaze-debug")
                }
                appModel.setupControlServer()
                // Auto-start the demo + gaze session so the experience runs
                // even if the laptop control page never connects (school
                // Wi-Fi blocking, hotspot off, etc.). The operator can still
                // press End / Start new session from the control page when
                // it's working — those overwrite this auto-started session.
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
    }
}
