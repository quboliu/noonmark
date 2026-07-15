public struct WorkspaceSelectionModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Extend from the current anchor through the requested item.
    public static let range = Self(rawValue: 1 << 0)

    /// Preserve the existing selection and toggle or add the requested item.
    public static let additive = Self(rawValue: 1 << 1)
}

/// Platform-independent selection semantics for a desktop collection.
///
/// The model owns the anchor and keyboard focus so SwiftUI rows do not each
/// reinvent Command-click, Shift-click, Select All, and arrow-key behavior.
public struct WorkspaceSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var selectedIDs: Set<ID>
    public private(set) var anchorID: ID?
    public private(set) var focusedID: ID?

    public init(
        selectedIDs: Set<ID> = [],
        anchorID: ID? = nil,
        focusedID: ID? = nil
    ) {
        self.selectedIDs = selectedIDs
        self.anchorID = anchorID
        self.focusedID = focusedID
    }

    public var isEmpty: Bool { selectedIDs.isEmpty }
    public var count: Int { selectedIDs.count }

    public func contains(_ id: ID) -> Bool {
        selectedIDs.contains(id)
    }

    public mutating func select(
        _ id: ID,
        in orderedIDs: [ID],
        modifiers: WorkspaceSelectionModifiers = []
    ) {
        let orderedIDs = unique(orderedIDs)
        guard orderedIDs.contains(id) else {
            replace(with: id)
            return
        }

        if modifiers.contains(.range), let anchorID, let anchorIndex = orderedIDs.firstIndex(of: anchorID), let requestedIndex = orderedIDs.firstIndex(of: id) {
            let bounds = min(anchorIndex, requestedIndex)...max(anchorIndex, requestedIndex)
            let rangeIDs = Set(bounds.map { orderedIDs[$0] })
            if modifiers.contains(.additive) {
                selectedIDs.formUnion(rangeIDs)
            } else {
                selectedIDs = rangeIDs
            }
            focusedID = id
            return
        }

        if modifiers.contains(.additive) {
            if selectedIDs.remove(id) == nil {
                selectedIDs.insert(id)
            }
            anchorID = id
            focusedID = id
            if selectedIDs.isEmpty {
                anchorID = nil
            }
            return
        }

        replace(with: id)
    }

    public mutating func moveFocus(
        by offset: Int,
        in orderedIDs: [ID],
        extendingRange: Bool = false
    ) {
        let orderedIDs = unique(orderedIDs)
        guard orderedIDs.isEmpty == false else {
            clear()
            return
        }
        let currentIndex = focusedID.flatMap { orderedIDs.firstIndex(of: $0) }
            ?? anchorID.flatMap { orderedIDs.firstIndex(of: $0) }
            ?? (offset < 0 ? orderedIDs.count : -1)
        let nextIndex = min(max(currentIndex + offset, 0), orderedIDs.count - 1)
        select(
            orderedIDs[nextIndex],
            in: orderedIDs,
            modifiers: extendingRange ? .range : []
        )
    }

    public mutating func selectAll(in orderedIDs: [ID]) {
        let orderedIDs = unique(orderedIDs)
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
        focusedID = orderedIDs.last
    }

    public mutating func retainOnly(_ availableIDs: [ID]) {
        let available = Set(availableIDs)
        selectedIDs.formIntersection(available)
        if let anchorID, available.contains(anchorID) == false {
            self.anchorID = selectedIDs.first
        }
        if let focusedID, available.contains(focusedID) == false {
            self.focusedID = anchorID
        }
        if selectedIDs.isEmpty {
            anchorID = nil
            focusedID = nil
        }
    }

    public mutating func clear() {
        selectedIDs.removeAll()
        anchorID = nil
        focusedID = nil
    }

    private mutating func replace(with id: ID) {
        selectedIDs = [id]
        anchorID = id
        focusedID = id
    }

    private func unique(_ ids: [ID]) -> [ID] {
        var seen: Set<ID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
