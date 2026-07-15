import SwiftUI

struct WorkspaceBulkActionBar: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        if store.selectedWorkspaceItemCount > 1 {
            HStack(spacing: 10) {
                Text(store.copy.selectedTaskCount(store.selectedWorkspaceItemCount))
                    .font(.noonmarkSystem(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .accessibilityIdentifier("workspace.selection.count")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "workspace.selection.count.e2e",
                            verificationText: String(store.selectedWorkspaceItemCount)
                        )
                    }

                Spacer(minLength: 12)

                if store.canBulkCompleteSelection {
                    actionButton(
                        store.copy.completeSelectedTasks,
                        systemImage: "checkmark.circle",
                        identifier: "workspace.bulk.complete.e2e",
                        action: store.completeSelectedTasks
                    )
                }

                if store.canBulkScheduleSelectionToday {
                    actionButton(
                        store.copy.scheduleSelectedToday,
                        systemImage: "calendar.badge.plus",
                        identifier: "workspace.bulk.schedule-today.e2e",
                        action: store.scheduleSelectedPoolTasksForToday
                    )
                }

                if store.canBulkReturnSelectionToPool {
                    actionButton(
                        store.copy.returnSelectedToPool,
                        systemImage: "tray.and.arrow.down",
                        identifier: "workspace.bulk.return-pool.e2e",
                        action: store.returnSelectedFutureTasksToPool
                    )
                }

                Button(store.copy.clearTaskSelection) {
                    store.clearSelection()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .background {
                    AppE2EViewAnchor(
                        identifier: "workspace.bulk.clear.e2e",
                        verificationText: store.copy.clearTaskSelection
                    )
                }
            }
            .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
            .frame(minHeight: 38)
            .background(
                Theme.controlFill.opacity(
                    Theme.shouldReduceTransparency ? 1 : 0.62
                )
            )
            .overlay(alignment: .bottom) {
                Divider().overlay(Theme.line)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.bulk-actions")
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background {
            AppE2EViewAnchor(identifier: identifier, verificationText: title)
        }
    }
}
