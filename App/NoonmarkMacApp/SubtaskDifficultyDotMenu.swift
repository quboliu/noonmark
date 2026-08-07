import NoonmarkCore
import SwiftUI

enum SubtaskRowMetrics {
    static let controlSpacing: CGFloat = 4
}

/// A compact visual affordance for a subtask's difficulty. The full, named
/// choices remain in the menu so the row can reserve its horizontal space for
/// the task title without hiding the setting from keyboard or VoiceOver users.
struct SubtaskDifficultyDotMenu: View {
    let difficulty: SubtaskDifficulty
    let copy: AppCopy
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let onSelect: (SubtaskDifficulty) -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(dotColor)
                .overlay {
                    Circle().strokeBorder(
                        Theme.line2.opacity(0.65),
                        lineWidth: 0.75
                    )
                }
                .frame(width: 10, height: 10)
                .allowsHitTesting(false)

            difficultyMenu
        }
        .frame(width: 12, height: 28)
        .background {
            AppE2EViewAnchor(identifier: accessibilityIdentifier)
        }
        .help(copy.subtaskDifficultyHelp(canMutate: isEnabled))
    }

    private var difficultyMenu: some View {
        Menu {
            ForEach(SubtaskDifficulty.allCases, id: \.self) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    Label(
                        copy.subtaskDifficulty(candidate),
                        systemImage: candidate == difficulty
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
            }
        } label: {
            Color.clear
                .frame(width: 10, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEnabled == false)
        .accessibilityLabel(copy.subtaskDifficultyHelp(canMutate: isEnabled))
        .accessibilityValue(copy.subtaskDifficulty(difficulty))
        .accessibilityIdentifier("\(accessibilityIdentifier).ax")
    }

    private var dotColor: Color {
        switch difficulty {
        case .simple:
            Theme.text3.opacity(0.58)
        case .medium:
            Theme.accent.opacity(0.72)
        case .hard:
            Theme.warn.opacity(0.92)
        }
    }
}
