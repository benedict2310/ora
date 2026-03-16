//
//  OverlayTaskStatusView.swift
//  Ora
//
//  Compact background-task status line shown at the bottom of the overlay.
//

import SwiftUI

struct OverlayTaskStatusView: View {
    @ObservedObject var taskProgressObserver: TaskProgressObserver
    let reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        HStack(spacing: 12) {
            Button(action: {
                self.taskProgressObserver.openTaskMenu()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: self.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(self.taskProgressObserver.statusLineText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("Cancel") {
                self.taskProgressObserver.cancelPrimaryTask()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background {
            if self.reduceTransparency {
                shape
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
                    .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
            } else {
                shape
                    .glassEffect(.regular.tint(.white.opacity(0.04)), in: shape)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.taskProgressObserver.statusLineText)
    }

    private var iconName: String {
        return self.taskProgressObserver.primaryTask?.phase.iconName ?? "arrow.triangle.2.circlepath"
    }
}
