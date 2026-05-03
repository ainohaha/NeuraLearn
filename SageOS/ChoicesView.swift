//
//  ChoicesView.swift
//  SageOS
//

import SwiftUI

struct ChoicesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Choices")
                .font(.largeTitle)
            Text("Placeholder — BCI controls go here.")
                .foregroundStyle(.secondary)
        }
        .padding(60)
        .frame(minWidth: 600, minHeight: 400)
    }
}
