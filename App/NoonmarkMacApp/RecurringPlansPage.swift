import NoonmarkCore
import SwiftUI

struct RecurringPlansPage: View {
    @EnvironmentObject private var store: NoonmarkStore

    private func listVerificationText(
        for tracks: [TaskCycleTrack]
    ) -> String {
        tracks.map {
            "\($0.title)|"
                + store.copy.taskCycleLifecycleSummary(
                    $0,
                    displayDate: store.displayDate
                )
        }.joined(separator: "\n")
    }

    var body: some View {
        let tracks = store.engine.taskCycleTracks(
            today: store.today
        )

        VStack(alignment: .leading, spacing: 0) {
            WorkspacePageHeader(
                title: store.copy.navRecurring,
                subtitle: store.copy.recurringPlansSubtitle
            )
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        TaskCycleTrackRow(track: track)
                    }
                    if tracks.isEmpty {
                        EmptyState(
                            kind: .recurringPlans,
                            text: store.copy.emptyRecurringPlans
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(
                    .horizontal,
                    NoonmarkVisualMetrics.pageHorizontalPadding
                )
                .padding(.top, 12)
                .padding(.bottom, 20)
                    .background {
                        AppE2EViewAnchor(
                            identifier: "recurring-plans.list",
                            verificationText:
                            listVerificationText(for: tracks)
                        )
                    }
            }
        }
    }
}
