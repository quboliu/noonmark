import NoonmarkCore

extension NoonmarkStore {
    func standaloneCollectionItems<Item>(
        _ items: [Item],
        chainID: (Item) -> TaskChainID
    ) -> [Item] {
        items.filter {
            engine.chains[chainID($0)]?.cycleMembership == nil
        }
    }

    func completedHierarchyParentSelection(
        _ hierarchy: CompletedTaskHierarchy
    ) -> WorkspaceSelectionItem? {
        if let completion = hierarchy.parentCompletion {
            return .completedTrace(completion.trace.id)
        }
        let pendingTraces = engine.traces.values.filter {
            trace in
            trace.chainID == hierarchy.chain.id
                && trace.status == .pending
        }
        if let currentTrace = pendingTraces.max(by: {
            lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.createdAt < rhs.createdAt
        }) {
            return currentTrace.date > today
                ? .futureTrace(currentTrace.id)
                : .dayTrace(currentTrace.id)
        }
        if engine.taskPool().contains(where: {
            $0.chain.id == hierarchy.chain.id
        }) {
            return .poolTask(hierarchy.chain.id)
        }
        if engine.unfinishedPool().contains(where: {
            $0.chain.id == hierarchy.chain.id
        }) {
            return .unfinishedTask(hierarchy.chain.id)
        }
        return nil
    }
}
