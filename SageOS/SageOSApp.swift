//
//  SageOSApp.swift
//  SageOS
//
//  Created by Aino Halonen on 4/3/26.
//

import SwiftUI

@main
struct SageOSApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: "opening") {
            ContentView()
                .environment(appModel)
        }

        WindowGroup(id: "choices") {
            ChoicesView()
                .environment(appModel)
        }
        .windowStyle(.plain)
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentSize)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView(url: appModel.currentScene.url)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
     }
}
