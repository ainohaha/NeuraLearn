//
//  ContentView.swift
//  SageOS
//
//  Created by Aino Halonen on 4/3/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .onAppear {
                Task {
                    await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    dismissWindow(id: "opening")
                    await appModel.runFlow(openWindow: openWindow)
                }
            }
    }
}
