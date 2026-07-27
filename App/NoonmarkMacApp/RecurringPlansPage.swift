import NoonmarkCore
import SwiftUI

struct RecurringPlansPage: View {
    @EnvironmentObject private var store: NoonmarkStore

    private var tracks: [TaskCycleTrack] {
        store.engine.taskCycleTracks(
            today: store.today,
            collection: .recurringPlans
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: store.copy.navRecurring,
                subtitle: store.copy.recurringPlansSubtitle
            )
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        TaskCycleTrackRow(
                            track: track,
                            collection: .recurringPlans
                        )
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
                        verificationText: "\(tracks.count)"
                    )
                }
            }
        }
    }
}
