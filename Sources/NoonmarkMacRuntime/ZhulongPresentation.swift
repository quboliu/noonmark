import Foundation
import NoonmarkCore

public enum ZhulongScopeCopyKey: String, CaseIterable, Sendable {
    case currentDayTodo
    case taskPool
    case unfinishedPool
    case completedPool
    case taskClassifications
}

public enum ZhulongSessionStateCopyKey: String, CaseIterable, Sendable {
    case noSelection
    case paused
    case archived
    case scopeReview
    case readyForProvider
    case providerRunning
    case decisionGate
    case draftReview
}

public enum ZhulongSessionStatusStyle: Sendable {
    case compact
    case expanded
}

public enum ZhulongEntryKindCopyKey: String, CaseIterable, Sendable {
    case userStatement
    case zhulongStatement
    case question
    case answer
    case decision
    case correction
}

public enum ZhulongEventCopyKey: String, CaseIterable, Sendable {
    case sessionCreated
    case scopeAuthorized
    case providerRunStarted
    case providerRunFailed
    case draftReady
    case sessionCorrected
    case sessionDecisionRecorded
    case planningBriefPublished
    case planningBriefReviewed
    case planningBriefInvalidated
    case planningDelegationGranted
    case planningDelegationConsumed
    case planningDelegationInvalidated
    case planningRunInvalidated
    case planningDecisionGateOpened
    case planningDecisionGateResolved
    case todoDiffPublished
    case todoDiffRevised
    case todoWriteAuthorized
    case todoBatchApplied
    case dailyCloseCaptured
    case unfinishedCauseProposed
    case unfinishedCauseResolved
    case dailyReviewDraftPublished
    case dailyReviewAuthorized
    case dailyReviewApplied
    case sessionPaused
    case sessionResumed
    case sessionArchived
}

public enum ZhulongWorkspaceOperationFailure: Equatable, Sendable {
    case sessionCreation
    case todoBatchApply
    case dailyReviewSave
    case providerRun
    case planningRun
    case sessionOperation
    case planningBriefSave
}

public enum ZhulongWorkspacePersistenceFailure: Equatable, Sendable {
    case applicationRecovery
    case memorySave
    case memoryRead
}

public enum ZhulongWorkspaceActivity: Equatable, Sendable {
    case applicationRecoveryConflict
    case applicationRecovered
    case applicationCommitRecoveryPending
    case applicationCommitVerifiedComplete
    case providerRunning
    case planningProviderRunning
    case e2eInterruption
}

public enum ZhulongWorkspaceNotice: Equatable, Sendable {
    case operationFailure(ZhulongWorkspaceOperationFailure)
    case persistenceFailure(ZhulongWorkspacePersistenceFailure)
    case activity(ZhulongWorkspaceActivity)
    case unverifiableSessions(Int)
    case diagnostic(String)

    public static let sessionCreationFailed = Self.operationFailure(.sessionCreation)
    public static let todoBatchApplyFailed = Self.operationFailure(.todoBatchApply)
    public static let dailyReviewSaveFailed = Self.operationFailure(.dailyReviewSave)
    public static let providerRunFailed = Self.operationFailure(.providerRun)
    public static let planningRunFailed = Self.operationFailure(.planningRun)
    public static let sessionOperationFailed = Self.operationFailure(.sessionOperation)
    public static let planningBriefSaveFailed = Self.operationFailure(.planningBriefSave)
    public static let applicationRecoveryFailed = Self.persistenceFailure(.applicationRecovery)
    public static let memorySaveFailed = Self.persistenceFailure(.memorySave)
    public static let memoryReadFailed = Self.persistenceFailure(.memoryRead)
    public static let applicationRecoveryConflict = Self.activity(.applicationRecoveryConflict)
    public static let applicationRecovered = Self.activity(.applicationRecovered)
    public static let applicationCommitRecoveryPending = Self.activity(
        .applicationCommitRecoveryPending
    )
    public static let applicationCommitVerifiedComplete = Self.activity(
        .applicationCommitVerifiedComplete
    )
    public static let providerRunning = Self.activity(.providerRunning)
    public static let planningProviderRunning = Self.activity(.planningProviderRunning)
    public static let e2eInterruption = Self.activity(.e2eInterruption)
}

public enum ZhulongApplicationCommitOperation: CaseIterable, Sendable {
    case todoBatch
    case dailyReview
}

public enum ZhulongCommitPresentationState: Equatable, Sendable {
    case cleanSuccess
    case failedBeforeCommit
    case recoveryPending
    case verifiedCompletion
}

public enum ZhulongApplicationCommitProgressEvidence: Equatable, Sendable {
    case beforeEngine
    case enginePersistenceUnresolved
    case enginePersisted
    case sessionPersisted
    case completed
}

public enum ZhulongApplicationJournalEvidence: Equatable, Sendable {
    case absent
    case presentOrUnverifiable
}

public enum ZhulongApplicationCommitNoticeProjection {
    public static func state(
        progress: ZhulongApplicationCommitProgressEvidence,
        recoveredCommitError: Bool,
        journal: ZhulongApplicationJournalEvidence
    ) -> ZhulongCommitPresentationState {
        switch progress {
        case .completed:
            recoveredCommitError
                ? .verifiedCompletion
                : .cleanSuccess
        case .enginePersistenceUnresolved, .enginePersisted:
            .recoveryPending
        case .sessionPersisted:
            journal == .absent
                ? .verifiedCompletion
                : .recoveryPending
        case .beforeEngine:
            journal == .absent
                ? .failedBeforeCommit
                : .recoveryPending
        }
    }

    public static func mutationFailureNotice(
        fallback: ZhulongWorkspaceNotice,
        journal: ZhulongApplicationJournalEvidence
    ) -> ZhulongWorkspaceNotice {
        if journal == .presentOrUnverifiable {
            return .applicationCommitRecoveryPending
        }
        return fallback
    }

    public static func noticeAfterConfirmedAbsentJournal(
        _ current: ZhulongWorkspaceNotice?
    ) -> ZhulongWorkspaceNotice? {
        current == .applicationCommitRecoveryPending ? nil : current
    }

    public static func notice(
        operation: ZhulongApplicationCommitOperation,
        state: ZhulongCommitPresentationState
    ) -> ZhulongWorkspaceNotice? {
        switch state {
        case .cleanSuccess:
            nil
        case .failedBeforeCommit:
            switch operation {
            case .todoBatch:
                .todoBatchApplyFailed
            case .dailyReview:
                .dailyReviewSaveFailed
            }
        case .recoveryPending:
            .applicationCommitRecoveryPending
        case .verifiedCompletion:
            .applicationCommitVerifiedComplete
        }
    }
}

public enum ZhulongTodoEditorKindCopyKey: Sendable {
    case createTask
    case addSubtask
    case scheduleFromPool
    case continueTrace
    case abandonChain
}

public enum ZhulongTodoValidationFailure: Sendable {
    case missingTitle
    case invalidDate
    case revisionFailed
}

public enum ZhulongProviderStatus: Equatable, Sendable {
    case notConfigured
    case savedWithCredential
    case savedWithoutCredential
    case disabled
}

public enum ZhulongProviderSettingsFailure: Sendable {
    case invalidBaseURL
    case emptyModel
    case keychainUnavailable
    case unexpected
}

public enum ZhulongProviderActionNotice: CaseIterable, Hashable, Sendable {
    case configurationSaved
    case saveFailed
    case configurationCleared
    case clearFailed
    case connectionTestSkippedDisabled
    case healthCheckUnsupported
    case connectionSucceeded
    case connectionFailed
    case providerNotEnabled
    case invalidConfiguration
}

public struct ZhulongCopy: Sendable {
    private static let englishEventTitles: [ZhulongEventCopyKey: String] = [
        .sessionCreated: "Zhulong session created",
        .scopeAuthorized: "Data scope authorised",
        .providerRunStarted: "Authorised content sent to the Provider",
        .providerRunFailed: "Provider request failed",
        .draftReady: "Provider returned a draft for review",
        .sessionCorrected: "Session correction appended",
        .sessionDecisionRecorded: "User decision recorded",
        .planningBriefPublished: "Planning brief published",
        .planningBriefReviewed: "User reviewed the planning brief",
        .planningBriefInvalidated: "A source correction invalidated the planning brief",
        .planningDelegationGranted: "One-time planning delegation created",
        .planningDelegationConsumed: "One-time planning delegation used",
        .planningDelegationInvalidated: "The previous planning delegation was invalidated",
        .planningRunInvalidated: "The previous planning run was invalidated",
        .planningDecisionGateOpened: "Planning paused for a user decision",
        .planningDecisionGateResolved: "User resolved the planning decision",
        .todoDiffPublished: "Editable Todo change diff published",
        .todoDiffRevised: "User created a Todo diff revision",
        .todoWriteAuthorized: "User granted a one-time Todo write",
        .todoBatchApplied: "Todo diff applied atomically",
        .dailyCloseCaptured: "Daily close facts captured",
        .unfinishedCauseProposed: "Zhulong proposed a cause for unfinished work",
        .unfinishedCauseResolved: "User reviewed the unfinished-work cause",
        .dailyReviewDraftPublished: "Editable AI review draft published",
        .dailyReviewAuthorized: "User granted a one-time review save",
        .dailyReviewApplied: "User-confirmed daily review saved",
        .sessionPaused: "Session paused",
        .sessionResumed: "Session resumed",
        .sessionArchived: "Session archived"
    ]
    private static let providerActionNotices: [ZhulongProviderActionNotice: (chinese: String, english: String)] = [
        .configurationSaved: ("Provider 配置已保存", "Provider configuration saved"),
        .saveFailed: ("Provider 配置未能保存，请稍后再试。", "Provider configuration could not be saved. Try again shortly."),
        .configurationCleared: ("Provider 配置已清空", "Provider configuration cleared"),
        .clearFailed: ("Provider 配置未能清空，请稍后再试。", "Provider configuration could not be cleared. Try again shortly."),
        .connectionTestSkippedDisabled: ("Provider 已关闭，未发起连接测试", "Provider is off; no connection test was started"),
        .healthCheckUnsupported: ("Provider 配置完整；该类型尚不支持远程健康检查", "Provider configuration is complete; remote health checks are not supported for this type"),
        .connectionSucceeded: ("Provider 连接成功", "Provider connection succeeded"),
        .connectionFailed: ("Provider 连接失败，请检查配置后重试。", "Provider connection failed. Check the configuration and try again."),
        .providerNotEnabled: ("Provider 尚未启用", "Provider is not enabled"),
        .invalidConfiguration: ("Provider 配置无效，请检查后重试。", "Provider configuration is invalid. Check it and try again.")
    ]

    private let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    public var name: String { localized(chinese: "烛龙", english: "Zhulong") }
    public var homeSubtitle: String {
        localized(
            chinese: "天东有若木，下置衔烛龙。 吾将斩龙足、嚼龙肉， 使之朝不得回、夜不得伏。",
            english: "Clarify what is vague and keep what is underway moving."
        )
    }

    public var intentPlaceholder: String {
        localized(chinese: "说说你现在想推进什么……", english: "What would you like to move forward?")
    }

    public var beginIntentAccessibilityLabel: String {
        localized(chinese: "开始梳理", english: "Start working through it")
    }

    public var suggestionMode: String { localized(chinese: "建议模式", english: "Suggestion mode") }
    public var pendingDecisionsTitle: String {
        localized(chinese: "待你决定", english: "Needs your decision")
    }

    public var continueAction: String { localized(chinese: "继续", english: "Continue") }
    public var pauseAction: String { localized(chinese: "暂停", english: "Pause") }
    public var allSessionsAction: String { localized(chinese: "全部会话", english: "All sessions") }
    public var sessionNextStep: String {
        localized(
            chinese: "下一步：继续同一条追加式会话流",
            english: "Next: continue in the same append-only session"
        )
    }

    public func itemCount(_ count: Int) -> String {
        switch language {
        case .chinese:
            "\(count) 项"
        case .english:
            count == 1 ? "1 item" : "\(count) items"
        }
    }

    public func workflowAccessibilityLabel(title: String, detail: String) -> String {
        localized(chinese: "开始\(title)：\(detail)", english: "Start \(title): \(detail)")
    }

    public var taskShapingTitle: String {
        localized(chinese: "把模糊任务变成计划", english: "Turn a fuzzy task into a plan")
    }

    public var taskShapingDetail: String {
        localized(
            chinese: "澄清目标与约束，形成可审查的规划和 Todo diff",
            english: "Clarify goals and constraints, then review the plan and Todo diff"
        )
    }

    public var taskShapingIntent: String {
        localized(chinese: "规划一个还很模糊的大任务", english: "Plan a large task that is still fuzzy")
    }

    public var dailyCloseTitle: String {
        localized(chinese: "结束今天并安排明天", english: "Close today and arrange tomorrow")
    }

    public var dailyCloseDetail: String {
        localized(
            chinese: "复盘今日事实，处置未完成任务并形成下一次承诺",
            english: "Review today, resolve unfinished work, and form the next commitment"
        )
    }

    public var dailyCloseIntent: String {
        localized(
            chinese: "结束今天并形成下一次可信承诺",
            english: "Close today and form the next credible commitment"
        )
    }

    public var schedulingTitle: String {
        localized(chinese: "重新安排任务", english: "Reschedule tasks")
    }

    public var schedulingDetail: String {
        localized(
            chinese: "基于任务池与未完成任务提出可确认的排期建议",
            english: "Suggest a reviewable schedule for pooled and unfinished tasks"
        )
    }

    public var schedulingIntent: String {
        localized(
            chinese: "给任务池和未完成任务重新排期",
            english: "Reschedule tasks from the pool and unfinished work"
        )
    }

    public var classificationTitle: String {
        localized(chinese: "整理分组与标签", english: "Organise groups and tags")
    }

    public var classificationDetail: String {
        localized(
            chinese: "审查现有分组与标签，并提出可确认的整理建议",
            english: "Review current groups and tags, then suggest changes for confirmation"
        )
    }

    public var classificationIntent: String {
        localized(chinese: "整理任务的分组与标签", english: "Organise task groups and tags")
    }

    public func sessionStatus(
        _ state: ZhulongSessionStateCopyKey,
        style: ZhulongSessionStatusStyle
    ) -> String {
        switch style {
        case .compact:
            compactSessionStatus(state)
        case .expanded:
            expandedSessionStatus(state)
        }
    }

    public var sessionFallbackTitle: String {
        localized(chinese: "烛龙会话", english: "Zhulong session")
    }

    public var sessionStreamVerificationTitle: String {
        localized(chinese: "烛龙会话流", english: "Zhulong session stream")
    }

    public var sessionTimelineTitle: String {
        localized(chinese: "会话轨迹", english: "Session trail")
    }

    public var confirmScopeTitle: String {
        localized(chinese: "开始前，确认本次阅读范围", english: "Before we begin, confirm this reading scope")
    }

    public var sharedDecisionTitle: String {
        localized(chinese: "共同决策点", english: "Shared decision")
    }

    public var waitingForYou: String { localized(chinese: "需要你的确认", english: "Needs your confirmation") }
    public var scopeDisclosure: String {
        localized(
            chinese: "烛龙只读取下列范围形成可审查结果；规划委托、Todo 写入和长期记忆仍分别确认。",
            english: "Zhulong reads only the scopes below to produce a reviewable result. Planning, Todo writes, and long-term memory each require separate confirmation."
        )
    }

    public var useThisSessionOnly: String {
        localized(chinese: "仅在本次会话使用", english: "Use for this session only")
    }

    public func scopeConfirmed(providerEnabled: Bool) -> String {
        if providerEnabled {
            return localized(
                chinese: "范围已经确认。运行前将按右侧披露的范围构造本次 Provider 请求。",
                english: "Scope confirmed. The Provider request will use only the scope disclosed on the right."
            )
        }
        return localized(
            chinese: "范围已经确认。没有可用 Provider 时保持本地模式，不会用固定模板冒充模型结果。",
            english: "Scope confirmed. Without an available Provider, Zhulong stays local and never presents a fixed template as a model result."
        )
    }

    public var startGenerating: String { localized(chinese: "开始生成", english: "Start generating") }
    public var captureTodayFacts: String {
        localized(chinese: "捕获今日事实", english: "Capture today's facts")
    }

    public var decisionSupplementPlaceholder: String {
        localized(
            chinese: "补充你的取舍依据，可留空",
            english: "Add your reasoning, if useful"
        )
    }

    public var decisionChoiceNotice: String {
        localized(
            chinese: "选择后会追加一条用户决定；旧简报和旧委托随即失效。",
            english: "Choosing adds a user decision and immediately invalidates the previous brief and delegation."
        )
    }

    public var incorporateDecisionTitle: String {
        localized(chinese: "将新决定写入规划简报", english: "Add the new decision to the planning brief")
    }

    public var decisionRevisionNotice: String {
        localized(
            chinese: "决策门已经处置，但旧简报仍不具备执行权。建立新版本后必须重新审查和单次委托。",
            english: "The decision is resolved, but the previous brief still has no execution authority. Create, review, and delegate a new version."
        )
    }

    public var createRevisedBrief: String {
        localized(
            chinese: "建立包含新决定的简报版本",
            english: "Create a brief with the new decision"
        )
    }

    public var dailyReviewTitle: String { localized(chinese: "每日收尾复盘", english: "Daily close review") }
    public var awaitingConfirmation: String {
        localized(chinese: "待你确认", english: "Awaiting confirmation")
    }

    public var saved: String { localized(chinese: "已保存", english: "Saved") }
    public func providerSuggestion(_ suggestion: String) -> String {
        localized(chinese: "Provider 建议：\(suggestion)", english: "Provider suggestion: \(suggestion)")
    }

    public var dailyReviewSavedNotice: String {
        localized(
            chinese: "复盘已保存到当天记录；Todo 处置仍使用独立 Todo diff。",
            english: "The review is saved to the day record. Todo changes still use a separate diff."
        )
    }

    public var dailyReviewSummaryPlaceholder: String {
        localized(chinese: "今天发生了什么？", english: "What happened today?")
    }

    public var dailyReviewTomorrowPlaceholder: String {
        localized(
            chinese: "明天开始前提醒自己什么？",
            english: "What should you remember before tomorrow begins?"
        )
    }

    public var createReviewDraft: String {
        localized(chinese: "形成复盘草稿", english: "Create review draft")
    }

    public var confirmAndSaveReview: String {
        localized(chinese: "确认并保存复盘", english: "Confirm and save review")
    }

    public var reviewBoundaryNotice: String {
        localized(
            chinese: "复盘文本和 Todo 变更分开确认；保存不会改写已锁定的日轨迹。",
            english: "Review text and Todo changes are confirmed separately. Saving never rewrites a locked day trail."
        )
    }

    public var condenseBriefTitle: String {
        localized(chinese: "把初步结果收束为规划简报", english: "Turn the initial result into a planning brief")
    }

    public var conversationWorkflowBoundary: String {
        localized(
            chinese: "需要保存复盘、形成规划或写入 Todo 时，再进入相应的确认流程。",
            english: "Enter the relevant confirmation flow only when you want to save a review, make a plan, or change Todo."
        )
    }

    public var openDailyReviewWorkflow: String {
        localized(chinese: "整理为今日复盘", english: "Turn into today’s review")
    }

    public var openPlanningWorkflow: String {
        localized(chinese: "整理为规划简报", english: "Turn into a planning brief")
    }

    public var goalPlaceholder: String { localized(chinese: "目标", english: "Goal") }
    public var successCriteriaPlaceholder: String {
        localized(chinese: "成功标准，每行一项", english: "Success criteria, one per line")
    }

    public var hardConstraintsPlaceholder: String {
        localized(
            chinese: "硬约束，可留空；每行一项",
            english: "Hard constraints, one per line; optional"
        )
    }

    public var savePlanningBrief: String {
        localized(chinese: "保存规划简报", english: "Save planning brief")
    }

    public func planningBriefTitle(version: Int) -> String {
        localized(chinese: "规划简报 v\(version)", english: "Planning brief v\(version)")
    }

    public var reviewed: String { localized(chinese: "已审查", english: "Reviewed") }
    public var awaitingReview: String { localized(chinese: "待审查", english: "Awaiting review") }
    public var successCriteriaTitle: String {
        localized(chinese: "成功标准", english: "Success criteria")
    }

    public var confirmBrief: String {
        localized(chinese: "确认简报内容", english: "Confirm brief")
    }

    public var delegatePlanningOnce: String {
        localized(chinese: "单次委托规划", english: "Delegate planning once")
    }

    public var runThisPlanning: String {
        localized(chinese: "运行本次规划", english: "Run this planning request")
    }

    public var providerRequiredForPlanning: String {
        localized(
            chinese: "规划委托已记录；配置 Provider 前不会生成模型规划。",
            english: "The planning delegation is recorded. No model plan is generated until a Provider is configured."
        )
    }

    public var planningDelegationBoundary: String {
        localized(
            chinese: "规划委托不包含 Todo 写入；后续 Todo diff 仍需单独批量确认。",
            english: "Planning delegation excludes Todo writes. Any later Todo diff still requires separate batch confirmation."
        )
    }

    public func planArtifactTitle(version: Int) -> String {
        localized(chinese: "规划产物 v\(version)", english: "Planning output v\(version)")
    }

    public func todoDiffReviewStatus(hasDiff: Bool) -> String {
        if hasDiff {
            return localized(chinese: "Todo diff 待确认", english: "Todo diff awaiting confirmation")
        }
        return localized(chinese: "待形成 Todo diff", english: "Todo diff not created")
    }

    public func deliverables(_ values: [String]) -> String {
        let separator = language == .chinese ? "；" : "; "
        return localized(chinese: "交付物：", english: "Deliverables: ") + values.joined(separator: separator)
    }

    public func todoDiffTitle(version: Int, count: Int) -> String {
        switch language {
        case .chinese:
            "Todo 变更 diff v\(version) · \(count) 项"
        case .english:
            "Todo change diff v\(version) · \(count == 1 ? "1 item" : "\(count) items")"
        }
    }

    public var reviewAndRevise: String { localized(chinese: "审查与修订", english: "Review and revise") }
    public var confirmAndApplyAtomically: String {
        localized(chinese: "批量确认并原子应用", english: "Confirm and apply atomically")
    }

    public var createReviewableTodoDiff: String {
        localized(chinese: "形成可审查 Todo diff", english: "Create a reviewable Todo diff")
    }

    public var todoAtomicBoundary: String {
        localized(
            chinese: "近期交付物先进入任务池；确认前不会写入，整批应用要么全部成功，要么全部回滚。",
            english: "Near-term deliverables enter the Task Pool first. Nothing is written before confirmation; the batch either succeeds completely or rolls back."
        )
    }

    public func planningStageNote(stageTitle: String) -> String {
        localized(chinese: "来自规划阶段：\(stageTitle)", english: "From planning stage: \(stageTitle)")
    }

    public func createTaskOperation(title: String, targetDate: String?) -> String {
        switch (language, targetDate) {
        case let (.chinese, .some(date)):
            "创建任务“\(title)”并排期到 \(date)"
        case (.chinese, .none):
            "创建任务池任务“\(title)”"
        case let (.english, .some(date)):
            "Create “\(title)” and schedule it for \(date)"
        case (.english, .none):
            "Create “\(title)” in the Task Pool"
        }
    }

    public func addSubtaskOperation(title: String) -> String {
        localized(chinese: "添加子任务“\(title)”", english: "Add subtask “\(title)”")
    }

    public func scheduleFromPoolOperation(targetDate: String) -> String {
        localized(
            chinese: "从任务池排期到 \(targetDate)",
            english: "Schedule from the Task Pool for \(targetDate)"
        )
    }

    public func continueTraceOperation(targetDate: String) -> String {
        localized(chinese: "延续任务到 \(targetDate)", english: "Continue task to \(targetDate)")
    }

    public var abandonChainOperation: String {
        localized(chinese: "废弃任务链", english: "Abandon task chain")
    }

    public var messageComposerPlaceholder: String {
        localized(chinese: "向烛龙发消息……", english: "Message Zhulong…")
    }

    public var messageComposerKeyboardHint: String {
        localized(chinese: "Enter 发送 · Shift+Enter 换行", english: "Enter to send · Shift+Enter for a new line")
    }

    public var composerScopeAuthorizationHint: String {
        localized(
            chinese: "请先确认本次阅读范围，再发送消息",
            english: "Confirm this session’s reading scope before sending"
        )
    }

    public var composerProviderRunningHint: String {
        localized(
            chinese: "烛龙正在回应…",
            english: "Zhulong is responding…"
        )
    }

    public var composerDecisionGateHint: String {
        localized(
            chinese: "请先完成当前确认，再继续对话",
            english: "Complete the current confirmation before continuing"
        )
    }

    public var composerPausedHint: String {
        localized(
            chinese: "会话已暂停；继续后即可发送",
            english: "This session is paused. Continue it to send"
        )
    }

    public func dossierSectionTitle(_ section: String) -> String {
        localized(chinese: "记录 · \(section)", english: "Record · \(section)")
    }

    public func chapterSectionTitle(number: Int, section: String) -> String {
        localized(
            chinese: "第 \(number) 节 · \(section)",
            english: "Chapter \(number) · \(section)"
        )
    }

    public var sendMessageAccessibilityLabel: String {
        localized(chinese: "发送给烛龙", english: "Send to Zhulong")
    }

    public var workspaceTitle: String { localized(chinese: "工作空间", english: "Workspace") }
    public var currentSessionTitle: String {
        localized(chinese: "当前会话", english: "Current session")
    }

    public var workspaceEmptyDescription: String {
        localized(
            chinese: "从自然语言入口建立会话。Provider、记忆和 Todo 写入继续使用各自独立边界。",
            english: "Start a session from natural language. Provider access, memory, and Todo writes keep separate boundaries."
        )
    }

    public var latestEventTitle: String { localized(chinese: "最新事件", english: "Latest event") }
    public func eventTimestamp(_ instant: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = language == .chinese
            ? Locale(identifier: "zh_Hans_SG")
            : Locale(identifier: "en_SG")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: instant)
    }

    public var currentIntentTitle: String { localized(chinese: "本次意图", english: "Current intent") }
    public var dataScopeTitle: String { localized(chinese: "数据范围", english: "Data scope") }
    public var providerBoundaryTitle: String {
        localized(chinese: "Provider 边界", english: "Provider boundary")
    }

    public var localProcessing: String { localized(chinese: "本地处理", english: "Processed locally") }
    public func remoteProcessing(model: String) -> String {
        localized(chinese: "远程发送 · \(model)", english: "Sent remotely · \(model)")
    }

    public var noProviderIdentity: String {
        localized(
            chinese: "尚未授权任何 Provider 配置身份",
            english: "No Provider configuration has been authorised"
        )
    }

    public var providerReauthorizationNotice: String {
        localized(
            chinese: "切换身份或扩大范围时必须重新确认。",
            english: "Changing identity or expanding scope requires confirmation again."
        )
    }

    public var memoryTitle: String { localized(chinese: "烛龙记忆", english: "Zhulong memory") }
    public var allowConfirmedMemory: String {
        localized(chinese: "允许使用已确认记忆", english: "Allow confirmed memory")
    }

    public func enabledMemoryDetail(count: Int) -> String {
        switch language {
        case .chinese:
            return "当前可用 \(count) 项；候选未经确认不会进入后续会话。"
        case .english:
            let countText = count == 1 ? "1 confirmed memory is" : "\(count) confirmed memories are"
            return "\(countText) available. Unconfirmed candidates never enter later sessions."
        }
    }

    public var disabledMemoryDetail: String {
        localized(
            chinese: "默认关闭。关闭时即使已有确认记录也不会进入提示上下文。",
            english: "Off by default. When off, even confirmed records stay out of prompt context."
        )
    }

    public func scopeTitle(_ scope: ZhulongScopeCopyKey) -> String {
        switch (language, scope) {
        case (.chinese, .currentDayTodo): "当前 Day Todo"
        case (.english, .currentDayTodo): "Current Day Todo"
        case (.chinese, .taskPool): "任务池"
        case (.english, .taskPool): "Task Pool"
        case (.chinese, .unfinishedPool): "未完成池"
        case (.english, .unfinishedPool): "Unfinished"
        case (.chinese, .completedPool): "已完成池"
        case (.english, .completedPool): "Completed"
        case (.chinese, .taskClassifications): "分组与标签"
        case (.english, .taskClassifications): "Groups & Tags"
        }
    }

    public func entryTitle(_ key: ZhulongEntryKindCopyKey) -> String {
        switch key {
        case .userStatement: localized(chinese: "用户说明", english: "User note")
        case .zhulongStatement: localized(chinese: "烛龙", english: "Zhulong")
        case .question: localized(chinese: "需要澄清", english: "Clarification needed")
        case .answer: localized(chinese: "用户回答", english: "User answer")
        case .decision: localized(chinese: "用户决定", english: "User decision")
        case .correction: localized(chinese: "追加更正", english: "Correction")
        }
    }

    public var userEyebrow: String { localized(chinese: "你", english: "You") }
    public var zhulongEyebrow: String { name }
    public var userDecisionEyebrow: String {
        localized(chinese: "用户决定", english: "User decision")
    }

    public var zhulongOutputEyebrow: String {
        localized(chinese: "烛龙产物", english: "Zhulong output")
    }

    public var historyBoundaryEyebrow: String {
        localized(chinese: "历史边界", english: "Historical boundary")
    }

    public var systemBoundaryEyebrow: String {
        localized(chinese: "系统边界", english: "System boundary")
    }

    public func eventTitle(
        _ key: ZhulongEventCopyKey,
        chineseAuditTitle: String
    ) -> String {
        guard language == .english else { return chineseAuditTitle }
        return Self.englishEventTitles[key] ?? "Zhulong session event"
    }

    public var scopeAuthorizationDetail: String {
        localized(
            chinese: "范围绑定当前 Provider 配置身份，有效期一小时；Todo 写入仍需另行确认。",
            english: "The scope is bound to the current Provider identity for one hour. Todo writes still require separate confirmation."
        )
    }

    public var planningDelegationDetail: String {
        localized(
            chinese: "这是一次性规划委托，不包含 Todo 写入或未来托管。",
            english: "This is a one-time planning delegation. It excludes Todo writes and future management."
        )
    }

    public var singleUseAuthorizationDetail: String {
        localized(
            chinese: "这项授权只可消费一次，并绑定当前草稿摘要。",
            english: "This authorisation can be used once and is bound to the current draft digest."
        )
    }

    public var applicationReceiptDetail: String {
        localized(
            chinese: "结果已形成不可重排的应用回执。",
            english: "The result is recorded in an immutable application receipt."
        )
    }

    public var invalidationDetail: String {
        localized(
            chinese: "原内容继续可审计，但不能恢复旧执行能力。",
            english: "The previous content remains auditable, but its execution authority cannot be restored."
        )
    }

    public var delegatedPlanningSuccessDetail: String {
        localized(
            chinese: "Provider 已返回结构化规划产物；原始响应保留在加密会话账本中。",
            english: "The Provider returned a structured planning output. The original response remains in the encrypted session ledger."
        )
    }

    public var providerFailureDetail: String {
        localized(
            chinese: "Provider 请求失败。请检查配置后重试。",
            english: "The Provider request failed. Check the configuration and try again."
        )
    }

    public func notice(_ notice: ZhulongWorkspaceNotice) -> String {
        switch notice {
        case let .operationFailure(failure):
            operationFailureMessage(failure)
        case let .persistenceFailure(failure):
            persistenceFailureMessage(failure)
        case let .activity(activity):
            activityMessage(activity)
        case let .unverifiableSessions(count):
            unverifiableSessionMessage(count: count)
        case let .diagnostic(message):
            message
        }
    }

    public var pendingApplicationMutationBlocked: String {
        localized(
            chinese: "烛龙写入仍待恢复；完成恢复前无法修改任务。",
            english: "Finish recovering the interrupted Zhulong change before editing tasks."
        )
    }

    public var todoEditorTitle: String {
        localized(chinese: "审查 Todo 变更", english: "Review Todo changes")
    }

    public func todoRevisionSubtitle(version: Int) -> String {
        localized(
            chinese: "基于 v\(version) 建立新修订；原版本继续保留在会话日志中。",
            english: "Create a revision from v\(version). The original remains in the session log."
        )
    }

    public var todoRevisionBoundary: String {
        localized(
            chinese: "保存修订不会写入 Todo；整批应用仍需再次确认。",
            english: "Saving a revision does not write to Todo. Applying the batch still requires confirmation."
        )
    }

    public var cancelAction: String { localized(chinese: "取消", english: "Cancel") }
    public var saveNewVersionAction: String {
        localized(chinese: "保存为新版本", english: "Save as new version")
    }

    public var splitAction: String { localized(chinese: "拆分", english: "Split") }
    public var removeTodoChangeAccessibilityLabel: String {
        localized(chinese: "移除这项 Todo 变更", english: "Remove this Todo change")
    }

    public var taskTitlePlaceholder: String {
        localized(chinese: "任务标题", english: "Task title")
    }

    public func targetDateTitle(required: Bool) -> String {
        if required {
            return localized(chinese: "目标日期", english: "Target date")
        }
        return localized(chinese: "目标日期（可留空）", english: "Target date (optional)")
    }

    public var isoDatePlaceholder: String { "YYYY-MM-DD" }

    public func todoEditorKindTitle(_ kind: ZhulongTodoEditorKindCopyKey) -> String {
        switch (language, kind) {
        case (.chinese, .createTask): "创建任务"
        case (.english, .createTask): "Create task"
        case (.chinese, .addSubtask): "添加子任务"
        case (.english, .addSubtask): "Add subtask"
        case (.chinese, .scheduleFromPool): "任务池排期"
        case (.english, .scheduleFromPool): "Schedule from Task Pool"
        case (.chinese, .continueTrace): "延续任务"
        case (.english, .continueTrace): "Continue task"
        case (.chinese, .abandonChain): "废弃任务链"
        case (.english, .abandonChain): "Abandon task chain"
        }
    }

    public func todoEditorFixedDescription(_ kind: ZhulongTodoEditorKindCopyKey) -> String {
        switch (language, kind) {
        case (.chinese, .scheduleFromPool): "将已有任务从任务池排期"
        case (.english, .scheduleFromPool): "Schedule an existing task from the Task Pool"
        case (.chinese, .continueTrace): "把未完成任务延续到新日期"
        case (.english, .continueTrace): "Continue unfinished work to a new date"
        case (.chinese, .abandonChain): "废弃当前任务链"
        case (.english, .abandonChain): "Abandon the current task chain"
        case (.chinese, .createTask), (.chinese, .addSubtask),
             (.english, .createTask), (.english, .addSubtask):
            ""
        }
    }

    public func todoValidationMessage(_ failure: ZhulongTodoValidationFailure) -> String {
        switch (language, failure) {
        case (.chinese, .missingTitle): "任务标题不能为空。"
        case (.english, .missingTitle): "Task title cannot be empty."
        case (.chinese, .invalidDate): "目标日期必须是有效的 YYYY-MM-DD。"
        case (.english, .invalidDate): "Target date must be a valid YYYY-MM-DD date."
        case (.chinese, .revisionFailed): "无法建立修订，请稍后再试。"
        case (.english, .revisionFailed): "The revision could not be created. Try again shortly."
        }
    }

    public func todoTitlePart(_ part: Int) -> String {
        localized(chinese: "（部分 \(part)）", english: " (Part \(part))")
    }

    public var customProviderName: String {
        localized(chinese: "自定义 Provider", english: "Custom Provider")
    }

    public func providerStatus(_ status: ZhulongProviderStatus) -> String {
        switch (language, status) {
        case (.chinese, .notConfigured): "未配置 Provider"
        case (.english, .notConfigured): "Provider not configured"
        case (.chinese, .savedWithCredential): "Provider 已保存，API Key 已就绪"
        case (.english, .savedWithCredential): "Provider saved; API key is ready"
        case (.chinese, .savedWithoutCredential): "Provider 已保存，未保存 API Key"
        case (.english, .savedWithoutCredential): "Provider saved without an API key"
        case (.chinese, .disabled): "烛龙已关闭，普通清单不受影响"
        case (.english, .disabled): "Zhulong is off; standard lists are unaffected"
        }
    }

    public func providerSettingsFailure(_ failure: ZhulongProviderSettingsFailure) -> String {
        switch (language, failure) {
        case (.chinese, .invalidBaseURL): "Base URL 必须使用 HTTPS；仅本机 loopback 可使用 HTTP。"
        case (.english, .invalidBaseURL): "Base URL must use HTTPS; only local loopback may use HTTP."
        case (.chinese, .emptyModel): "模型名称不能为空。"
        case (.english, .emptyModel): "Model name cannot be empty."
        case (.chinese, .keychainUnavailable): "无法保存 API Key，请稍后再试。"
        case (.english, .keychainUnavailable): "The API key could not be saved. Try again shortly."
        case (.chinese, .unexpected): "Provider 配置操作未完成，请稍后再试。"
        case (.english, .unexpected): "The Provider configuration action could not be completed. Try again shortly."
        }
    }

    public func providerActionNotice(_ notice: ZhulongProviderActionNotice) -> String {
        guard let text = Self.providerActionNotices[notice] else {
            return localized(
                chinese: "Provider 操作未完成，请稍后再试。",
                english: "The Provider action could not be completed. Try again shortly."
            )
        }
        return language == .chinese ? text.chinese : text.english
    }

    private func compactSessionStatus(_ state: ZhulongSessionStateCopyKey) -> String {
        switch state {
        case .noSelection: localized(chinese: "未选择会话", english: "No session selected")
        case .paused: localized(chinese: "已暂停", english: "Paused")
        case .archived: localized(chinese: "已归档", english: "Archived")
        case .scopeReview: localized(chinese: "等待范围确认", english: "Scope confirmation needed")
        case .readyForProvider: localized(chinese: "范围已确认", english: "Scope confirmed")
        case .providerRunning: localized(chinese: "Provider 正在运行", english: "Provider running")
        case .decisionGate: localized(chinese: "等待用户决定", english: "Waiting for your decision")
        case .draftReview: localized(chinese: "草稿待审", english: "Draft awaiting review")
        }
    }

    private func expandedSessionStatus(_ state: ZhulongSessionStateCopyKey) -> String {
        switch state {
        case .noSelection: localized(chinese: "未选择会话", english: "No session selected")
        case .paused: localized(chinese: "会话已暂停", english: "Session paused")
        case .archived: localized(chinese: "会话已归档", english: "Session archived")
        case .scopeReview: localized(chinese: "等待你确认本次范围", english: "Confirm this session's scope")
        case .readyForProvider: localized(chinese: "范围已确认，可以继续推进", english: "Scope confirmed; ready to continue")
        case .providerRunning: localized(chinese: "Provider 正在运行", english: "Provider running")
        case .decisionGate: localized(chinese: "等待你作出关键决定", english: "Waiting for your decision")
        case .draftReview: localized(chinese: "草稿已形成，等待审查", english: "Draft ready for review")
        }
    }

    private func operationFailureMessage(_ failure: ZhulongWorkspaceOperationFailure) -> String {
        switch failure {
        case .sessionCreation:
            localized(chinese: "无法建立会话，请稍后再试。", english: "The session could not be created. Try again shortly.")
        case .todoBatchApply:
            localized(chinese: "Todo 批次未能应用，未写入任何变更。", english: "The Todo batch could not be applied. No changes were written.")
        case .dailyReviewSave:
            localized(chinese: "每日复盘未能保存，未写入任何变更。", english: "The daily review could not be saved. No changes were written.")
        case .providerRun:
            localized(chinese: "Provider 运行失败，请检查配置后重试。", english: "The Provider run failed. Check the configuration and try again.")
        case .planningRun:
            localized(chinese: "规划运行失败，请稍后再试。", english: "The planning run failed. Try again shortly.")
        case .sessionOperation:
            localized(chinese: "会话操作未完成，请重试。", english: "The session action could not be completed. Try again.")
        case .planningBriefSave:
            localized(chinese: "无法保存规划简报，请检查内容后重试。", english: "The planning brief could not be saved. Check the content and try again.")
        }
    }

    private func persistenceFailureMessage(_ failure: ZhulongWorkspacePersistenceFailure) -> String {
        switch failure {
        case .applicationRecovery:
            localized(chinese: "无法恢复上次中断的烛龙写入，未自动修改 Todo。", english: "The interrupted Zhulong write could not be recovered. Todo was not changed automatically.")
        case .memorySave:
            localized(chinese: "无法保存记忆设置，请稍后再试。", english: "Memory settings could not be saved. Try again shortly.")
        case .memoryRead:
            localized(chinese: "无法读取烛龙记忆，记忆内容未载入。", english: "Zhulong memory could not be read and was not loaded.")
        }
    }

    private func activityMessage(_ activity: ZhulongWorkspaceActivity) -> String {
        switch activity {
        case .applicationRecoveryConflict:
            localized(chinese: "检测到未完成的烛龙写入，但当前 Todo 已有其他变化；已停止自动恢复。", english: "An interrupted Zhulong write was found, but Todo has changed since then. Automatic recovery stopped.")
        case .applicationRecovered:
            localized(chinese: "已恢复上次中断的烛龙原子写入。", english: "The interrupted Zhulong write was recovered.")
        case .applicationCommitRecoveryPending:
            localized(
                chinese: "烛龙原子写入尚未完整结束；后续写入已阻断，请先完成恢复。",
                english: "The Zhulong atomic write has not fully completed. Further writes are blocked until recovery finishes."
            )
        case .applicationCommitVerifiedComplete:
            localized(
                chinese: "烛龙写入曾返回错误，但系统已精确核对并完成提交；本次未显示普通成功提示。",
                english: "The Zhulong write returned an error, but its exact state was verified and the commit completed. The usual success confirmation was suppressed."
            )
        case .providerRunning:
            localized(chinese: "Provider 正在处理已授权内容。", english: "The Provider is processing authorised content.")
        case .planningProviderRunning:
            localized(chinese: "Provider 正在执行本次单次规划委托。", english: "The Provider is running this one-time planning delegation.")
        case .e2eInterruption:
            localized(chinese: "E2E：已在 SQLite 提交后中断，等待重启恢复。", english: "E2E: interrupted after the SQLite commit; waiting for restart recovery.")
        }
    }

    private func unverifiableSessionMessage(count: Int) -> String {
        switch language {
        case .chinese:
            "有 \(count) 个加密会话无法验证，内容未载入。"
        case .english:
            count == 1
                ? "1 encrypted session could not be verified and was not loaded."
                : "\(count) encrypted sessions could not be verified and were not loaded."
        }
    }

    private func localized(chinese: String, english: String) -> String {
        language == .chinese ? chinese : english
    }
}

public extension AppPresentation {
    var zhulong: ZhulongCopy {
        ZhulongCopy(language: language)
    }
}
