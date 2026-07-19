import Foundation

/// Restorable visibility preferences for the main three-column workspace.
/// Divider geometry is owned by NSSplitView's native autosave contract.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let defaultValue = WorkspaceState(
        sidebarExpanded: true,
        detailExpanded: false,
        usesCustomDetailWidth: false
    )

    public var sidebarExpanded: Bool
    public var detailExpanded: Bool
    public var usesCustomDetailWidth: Bool

    public init(
        sidebarExpanded: Bool,
        detailExpanded: Bool,
        usesCustomDetailWidth: Bool = false
    ) {
        self.sidebarExpanded = sidebarExpanded
        self.detailExpanded = detailExpanded
        self.usesCustomDetailWidth = usesCustomDetailWidth
    }

    private enum CodingKeys: String, CodingKey {
        case sidebarExpanded
        case detailExpanded
        case usesCustomDetailWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarExpanded = try container.decode(Bool.self, forKey: .sidebarExpanded)
        detailExpanded = try container.decode(Bool.self, forKey: .detailExpanded)
        usesCustomDetailWidth = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesCustomDetailWidth
        ) ?? false
    }
}

public enum WorkspaceGeometry {
    public static let defaultSidebarWidth = 220.0
    public static let defaultDetailWidth = 280.0
    public static let sidebarWidthRange = 180.0 ... 320.0
    public static let detailWidthRange = 240.0 ... 420.0
}

/// A small persistence boundary around UserDefaults. Production enables it;
/// deterministic E2E launches may explicitly disable it without branching the
/// split-view implementation itself.
@MainActor
public final class WorkspaceStateRepository {
    public static let defaultStorageKey = "Noonmark.WorkspaceState.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    public let persistenceEnabled: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = WorkspaceStateRepository.defaultStorageKey,
        persistenceEnabled: Bool = true
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.persistenceEnabled = persistenceEnabled
    }

    public func load() -> WorkspaceState {
        guard persistenceEnabled,
              let data = defaults.data(forKey: storageKey),
              let decoded = try? decoder.decode(WorkspaceState.self, from: data)
        else {
            return .defaultValue
        }
        return decoded
    }

    public var containsSavedState: Bool {
        persistenceEnabled && defaults.data(forKey: storageKey) != nil
    }

    public func save(_ state: WorkspaceState) {
        guard persistenceEnabled,
              let data = try? encoder.encode(state)
        else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    public func reset() {
        guard persistenceEnabled else { return }
        defaults.removeObject(forKey: storageKey)
    }
}
