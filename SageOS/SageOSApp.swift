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
        // The opening window stays alive for the whole app launch — it
        // owns the SwiftUI environment closures that open/close the
        // immersive space when the operator presses Start/End on the laptop
        // dashboard. It is sized to its 1-pt content (see ContentView) so
        // the participant in Guest Mode barely registers it, but it cannot
        // be dismissed without breaking inter-session reset.
        // Persistent invisible launcher. The window MUST stay alive for the
        // whole app launch because it owns the openImmersiveSpace /
        // dismissImmersiveSpace environment actions — the only way to
        // reset Spline back to `hello` between participants (SplineRuntime
        // has no reload API). Three layers strip all visibility:
        //   1. .windowStyle(.plain) removes the system chrome (grab handle,
        //      close button — the small icon participants would otherwise
        //      see floating in their peripheral view).
        //   2. .glassBackgroundEffect(displayMode: .never) removes the
        //      tinted glass plate that backs every visionOS window by
        //      default.
        //   3. Color.clear at 1pt is the actual content.
        WindowGroup(id: "opening") {
            ContentView()
                .environment(appModel)
                .glassBackgroundEffect(displayMode: .never)
                .persistentSystemOverlays(.hidden)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView(url: appModel.sessionURL)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
     }
}
