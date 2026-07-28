import NoonmarkCore

public enum AppOperationFailureContext: CaseIterable, Hashable, Sendable {
    case taskMutation
    case noteMutation
    case dailyReview
    case preferences
    case persistence
    case sync
    case provider
    case dataTransfer
    case undo
    case redo
    case naturalDay
    case databaseLoad
}

public enum AppSyncFailureReason: CaseIterable, Hashable, Sendable {
    case baselineUnavailable
    case baselineInvalid
    case baselineNotUploaded
    case localRecordsUnpreparable
    case localChangesPending
    case remoteChangesPending
}

private struct AppOperationFailureCopy {
    let chinese: String
    let english: String
}

private extension AppOperationFailureContext {
    static let copyByContext: [Self: AppOperationFailureCopy] = [
        .taskMutation: .init(
            chinese: "任务修改未完成，请检查当前日期与任务状态后重试。",
            english: "The task could not be changed. Check its date and status, then try again."
        ),
        .noteMutation: .init(
            chinese: "附言修改未完成，请刷新后重试。",
            english: "The note could not be changed. Refresh and try again."
        ),
        .dailyReview: .init(
            chinese: "每日复盘暂时无法保存，请稍后重试。",
            english: "The daily review could not be saved. Try again shortly."
        ),
        .preferences: .init(
            chinese: "设置未能保存，请稍后重试。",
            english: "The setting could not be saved. Try again shortly."
        ),
        .persistence: .init(
            chinese: "更改未能安全保存，现有数据保持不变。",
            english: "The change could not be saved safely. Existing data is unchanged."
        ),
        .sync: .init(
            chinese: "同步未完成；本机数据仍安全保留。请检查同步端点、账户、网络和可用磁盘空间后重试。",
            english: "Sync did not complete. Local data is still retained; check the sync endpoint, account, network, and available disk space, then try again."
        ),
        .provider: .init(
            chinese: "Provider 操作未完成，请检查配置与连接后重试。",
            english: "The provider action did not complete. Check its configuration and connection, then try again."
        ),
        .dataTransfer: .init(
            chinese: "数据操作未完成，现有数据保持不变。",
            english: "The data operation did not complete. Existing data is unchanged."
        ),
        .undo: .init(
            chinese: "无法安全撤销这项操作；当前数据保持不变。",
            english: "This action could not be undone safely. Current data is unchanged."
        ),
        .redo: .init(
            chinese: "无法安全重做这项操作；当前数据保持不变。",
            english: "This action could not be redone safely. Current data is unchanged."
        ),
        .naturalDay: .init(
            chinese: "暂时无法安全确认当前日期；任务修改已暂停，请重试。",
            english: "The current date could not be established safely. Task changes are paused; try again."
        ),
        .databaseLoad: .init(
            chinese: "本地数据暂时无法读取。为避免覆盖，编辑功能已暂停。",
            english: "Local data could not be read. Editing is paused to prevent an overwrite."
        )
    ]

    var copy: AppOperationFailureCopy {
        guard let copy = Self.copyByContext[self] else {
            preconditionFailure("Missing operation failure presentation copy for \(self)")
        }
        return copy
    }
}

public extension AppPresentation {
    func failureMessage(for context: AppOperationFailureContext) -> String {
        let copy = context.copy
        return language == .chinese ? copy.chinese : copy.english
    }

    func syncFailureMessage(for reason: AppSyncFailureReason) -> String {
        switch (language, reason) {
        case (.chinese, .baselineUnavailable):
            "同步未完成：无法建立本机完整数据基线。系统没有将本次操作标记为成功；本机数据仍然保留，请重试。"
        case (.chinese, .baselineInvalid):
            "同步未完成：本机同步基线不完整或已损坏。系统没有将本次操作标记为成功；请勿删除本机数据，重试后仍出现时请重新导入原数据包或联系支持。"
        case (.chinese, .baselineNotUploaded):
            "同步未完成：本机完整数据尚未全部上传。系统没有将本次操作标记为成功；请确认同步端点可用后重试。"
        case (.chinese, .localRecordsUnpreparable):
            "同步未完成：部分本机数据无法安全生成同步记录。系统没有将本次操作标记为成功；本机数据仍然保留，请重试。"
        case (.chinese, .localChangesPending):
            "同步未完成：结束同步时仍有新的本机更改等待上传。系统没有将本次操作标记为成功；本机数据仍然保留，请重试。"
        case (.chinese, .remoteChangesPending):
            "同步未完成：结束同步时仍有新的远端更改到达。系统没有将本次操作标记为成功；本机数据仍然保留，请重试。"
        case (.english, .baselineUnavailable):
            "Sync did not complete: the complete local data baseline could not be created. This operation was not marked as successful; local data is still retained. Try again."
        case (.english, .baselineInvalid):
            "Sync did not complete: the local sync baseline is incomplete or corrupted. This operation was not marked as successful; keep the local data, then reimport the original data package or contact support."
        case (.english, .baselineNotUploaded):
            "Sync did not complete: the complete local data has not been fully uploaded. This operation was not marked as successful; check the sync endpoint and try again."
        case (.english, .localRecordsUnpreparable):
            "Sync did not complete: some local data could not be safely converted into sync records. This operation was not marked as successful; local data is still retained. Try again."
        case (.english, .localChangesPending):
            "Sync did not complete: new local changes were still waiting to upload while sync was finishing. This operation was not marked as successful; local data is still retained. Try again."
        case (.english, .remoteChangesPending):
            "Sync did not complete: new remote changes were still arriving while sync was finishing. This operation was not marked as successful; local data is still retained. Try again."
        }
    }
}
