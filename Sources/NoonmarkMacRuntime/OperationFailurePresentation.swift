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
            chinese: "同步未完成，本机数据保持不变；请检查账户或网络后重试。",
            english: "Sync did not complete. Local data is unchanged; check your account or network and try again."
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
}
