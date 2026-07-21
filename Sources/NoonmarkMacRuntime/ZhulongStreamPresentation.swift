import Foundation
import NoonmarkCore

public enum ZhulongStreamView: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case conversation
    case dossier
    case chapters
    case weave

    public var id: String { rawValue }

    public func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.conversation, .chinese): "对话"
        case (.conversation, .english): "Conversation"
        case (.dossier, .chinese): "连续卷宗"
        case (.dossier, .english): "Continuous dossier"
        case (.chapters, .chinese): "章节手风琴"
        case (.chapters, .english): "Chapter accordion"
        case (.weave, .chinese): "双轨编织流"
        case (.weave, .english): "Dual-track weave"
        }
    }

    public func purpose(language: AppLanguage) -> String {
        switch (self, language) {
        case (.conversation, .chinese): "像普通聊天一样连续交流"
        case (.conversation, .english): "Work in a familiar chat flow"
        case (.dossier, .chinese): "按时间审阅全部事实"
        case (.dossier, .english): "Review every fact in time order"
        case (.chapters, .chinese): "按阶段收拢长会话"
        case (.chapters, .english): "Condense long sessions by stage"
        case (.weave, .chinese): "分开查看烛龙工作与用户决定"
        case (.weave, .english): "Separate Zhulong work from user decisions"
        }
    }
}

@MainActor
public final class ZhulongStreamViewRepository {
    public static let defaultStorageKey = "Noonmark.ZhulongStreamView.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = ZhulongStreamViewRepository.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> ZhulongStreamView {
        guard let rawValue = defaults.string(forKey: storageKey),
              let view = ZhulongStreamView(rawValue: rawValue)
        else { return .conversation }
        return view
    }

    public func save(_ view: ZhulongStreamView) {
        defaults.set(view.rawValue, forKey: storageKey)
    }
}
