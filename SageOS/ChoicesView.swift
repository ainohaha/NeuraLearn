//
//  ChoicesView.swift
//  SageOS
//

import SwiftUI

struct ChoicesView: View {
    @Environment(AppModel.self) private var appModel

    private let choices = ["Math", "Reading", "Music", "Art"]

    @State private var revealed: Set<Int> = []

    var body: some View {
        VStack(spacing: 16) {
            ForEach(choices.indices, id: \.self) { i in
                ChoiceCard(label: choices[i], isOpen: revealed.contains(i)) {
                    // selection handler — wire later
                }
            }
        }
        .padding(40)
        .frame(width: 700)
        .task {
            for i in choices.indices {
                withAnimation(.easeInOut(duration: 1.0)) {
                    _ = revealed.insert(i)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct ChoiceCard: View {
    let label: String
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var fillOpacity: Double {
        guard isOpen else { return 0 }
        return isHovering ? 0.55 : 0.40
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 90)
                .padding(.horizontal, 28)
                .opacity(isOpen ? 1 : 0)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(fillOpacity), in: .rect(cornerRadius: 28))
        .scaleEffect(y: isOpen ? 1 : 0.02, anchor: .top)
        .offset(y: isOpen ? 0 : -12)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.3), value: isHovering)
    }
}
