import SplineRuntime
import SwiftUI

struct ImmersiveView: ImmersiveSpaceContent {
    let url: URL

    var body: some ImmersiveSpaceContent {
        SplineImmersiveSpaceContent(sceneFileURL: url)
    }
}
