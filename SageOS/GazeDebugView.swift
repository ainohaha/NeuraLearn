//
//  GazeDebugView.swift
//  SageOS
//
//  Developer-only verification window. Shows live head-pose gaze proxy state
//  and lets the operator force-advance scenes. Disable via
//  AppModel.debugLiveOverlay before handing the headset to a participant.
//

import SwiftUI

struct GazeDebugView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stats
            trail
            controls
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 380)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(appModel.gaze.isRecording ? .green : .gray)
                .frame(width: 10, height: 10)
            Text(appModel.gaze.isRecording ? "Recording" : "Idle")
                .font(.headline)
            Spacer()
            Text("Scene \(appModel.sceneIndex + 1)/\(AppModel.scenes.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        let s = appModel.gaze.lastSample
        let gateLabel = appModel.currentScene.duration.map { "timer \(Int($0))s" } ?? "button-gated"
        return VStack(alignment: .leading, spacing: 4) {
            Text("Scene id: \(appModel.currentScene.id)  (\(gateLabel))")
            Text("Provider: \(appModel.gaze.providerState)")
                .foregroundStyle(appModel.gaze.providerState.contains("running") ? .green : .orange)
            Text("Samples: \(appModel.gaze.sampleCount)")
            Text(String(format: "Yaw:   %+6.1f°", degrees(s?.yaw)))
                .monospacedDigit()
            Text(String(format: "Pitch: %+6.1f°", degrees(s?.pitch)))
                .monospacedDigit()
            if let err = appModel.gaze.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private var trail: some View {
        Canvas { ctx, size in
            let samples = appModel.gaze.recentSamples
            guard samples.count >= 2 else { return }

            // Auto-fit yaw/pitch to a small padded window around the recent
            // trail so the dot stays inside the canvas as the user looks around.
            let yaws = samples.map { Double($0.yaw) * 180 / .pi }
            let pitches = samples.map { Double($0.pitch) * 180 / .pi }
            let yMin = (yaws.min() ?? 0) - 5
            let yMax = (yaws.max() ?? 0) + 5
            let pMin = (pitches.min() ?? 0) - 5
            let pMax = (pitches.max() ?? 0) + 5

            func pt(_ yaw: Double, _ pitch: Double) -> CGPoint {
                let x = (yaw - yMin) / max(yMax - yMin, 0.0001) * size.width
                // Invert pitch so +up is up on screen.
                let y = (1 - (pitch - pMin) / max(pMax - pMin, 0.0001)) * size.height
                return CGPoint(x: x, y: y)
            }

            // Fading polyline: older segments are dimmer.
            let n = samples.count
            for i in 1..<n {
                let alpha = Double(i) / Double(n)
                var path = Path()
                path.move(to: pt(Double(samples[i - 1].yaw) * 180 / .pi,
                                 Double(samples[i - 1].pitch) * 180 / .pi))
                path.addLine(to: pt(Double(samples[i].yaw) * 180 / .pi,
                                    Double(samples[i].pitch) * 180 / .pi))
                ctx.stroke(path, with: .color(.cyan.opacity(alpha)), lineWidth: 2)
            }

            // Current dot.
            let head = pt(Double(samples.last!.yaw) * 180 / .pi,
                          Double(samples.last!.pitch) * 180 / .pi)
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 5, y: head.y - 5,
                                            width: 10, height: 10)),
                     with: .color(.white))
        }
        .background(Color.black.opacity(0.85))
        .frame(height: 180)
        .cornerRadius(8)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Next scene") { appModel.advance() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if let url = appModel.gaze.lastLogURL {
                    Text(url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let url = appModel.advanceServerURL {
                Text("Laptop control: \(url)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Server starting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func degrees(_ r: Float?) -> Double {
        guard let r else { return 0 }
        return Double(r) * 180 / .pi
    }
}
