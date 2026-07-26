import NoonmarkCore
import SwiftUI

struct TaskCycleConversionMenuSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    let chainID: TaskChainID
    let traceID: DayTraceID?
    let accessibilityIdentifier: String

    var body: some View {
        if store.engine.chains[chainID]?.cycleMembership == nil {
            Divider()
            Button(store.copy.convertToRecurringTask) {
                store.beginTaskCycleConversion(
                    chainID: chainID,
                    traceID: traceID
                )
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
