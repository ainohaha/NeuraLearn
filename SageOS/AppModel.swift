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
    let duration: TimeInterval
    var opensWindowID: String? = nil
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

    // Publish each Spline scene to its own .splineswift URL, then drop it in here.
    // Order = playback order. duration = how long to hold before advancing.
    static let scenes: [SageScene] = [
        SageScene(
            id: "opening",
            url: URL(string: "https://build.spline.design/GHUXNEykQsZGOnNwvOlk/scene.splineswift")!,
            duration: 5.0
        ),
        SageScene(
            id: "choices",
            url: URL(string: "https://build.spline.design/GHUXNEykQsZGOnNwvOlk/scene.splineswift")!,
            duration: 1_000_000,
            opensWindowID: "choices"
        ),
    ]

    var sceneIndex: Int = 0
    var currentScene: SageScene { Self.scenes[sceneIndex] }

    func runFlow(openWindow: OpenWindowAction) async {
        for i in Self.scenes.indices {
            sceneIndex = i
            if let windowID = Self.scenes[i].opensWindowID {
                openWindow(id: windowID)
            }
            try? await Task.sleep(for: .seconds(Self.scenes[i].duration))
        }
    }
}
