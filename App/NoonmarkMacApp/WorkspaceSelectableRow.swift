import AppKit
import SwiftUI

struct WorkspaceSelectableRow: ViewModifier {
    @EnvironmentObject private var store: NoonmarkStore

    let item: NoonmarkStore.WorkspaceSelectionItem

    func body(content: Content) -> some View {
        let isSelected = store.isWorkspaceItemSelected(item)
        content
            .focusable(true)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                store.userSelectWorkspaceItem(item)
                return .handled
            }
            .onKeyPress(.space) {
                store.userSelectWorkspaceItem(item)
                return .handled
            }
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    store.moveWorkspaceSelection(
                        by: -1,
                        extendingRange: NSEvent.modifierFlags.contains(.shift)
                    )
                case .down:
                    store.moveWorkspaceSelection(
                        by: 1,
                        extendingRange: NSEvent.modifierFlags.contains(.shift)
                    )
                case .left, .right:
                    break
                @unknown default:
                    break
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("\(item.e2eIdentifier).ax")
            .accessibilityAction {
                store.userSelectWorkspaceItem(item)
            }
            .background {
                AppE2EViewAnchor(identifier: item.e2eIdentifier)
            }
    }
}

private extension NoonmarkStore.WorkspaceSelectionItem {
    var e2eIdentifier: String {
        switch self {
        case let .dayTrace(traceID):
            "workspace.item.day.\(traceID.description)"
        case let .poolTask(chainID):
            "workspace.item.pool.\(chainID.description)"
        case let .futureTrace(traceID):
            "workspace.item.future.\(traceID.description)"
        case let .unfinishedTask(chainID):
            "workspace.item.unfinished.\(chainID.description)"
        case let .completedTrace(traceID):
            "workspace.item.completed.\(traceID.description)"
        case let .completedSubtask(subtaskID):
            "workspace.item.completed-subtask.\(subtaskID.description)"
        }
    }
}

extension View {
    func workspaceSelectable(
        _ item: NoonmarkStore.WorkspaceSelectionItem
    ) -> some View {
        modifier(WorkspaceSelectableRow(item: item))
    }
}
