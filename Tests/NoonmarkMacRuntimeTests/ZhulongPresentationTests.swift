import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class ZhulongPresentationTests: XCTestCase {
    func testHomeAndWorkspaceCopyIsBilingual() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong

        XCTAssertEqual(chinese.homeSubtitle, "把模糊的事想清楚，把已经开始的事继续推进。")
        XCTAssertEqual(english.homeSubtitle, "Clarify what is vague and keep what is underway moving.")
        XCTAssertEqual(chinese.intentPlaceholder, "说说你现在想推进什么……")
        XCTAssertEqual(english.intentPlaceholder, "What would you like to move forward?")
        XCTAssertEqual(chinese.pendingDecisionsTitle, "待你决定")
        XCTAssertEqual(english.pendingDecisionsTitle, "Needs your decision")
        XCTAssertEqual(chinese.itemCount(2), "2 项")
        XCTAssertEqual(english.itemCount(1), "1 item")
        XCTAssertEqual(english.itemCount(2), "2 items")
    }

    func testScopeAndSessionStatesAreCompleteInBothLanguages() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong

        XCTAssertEqual(chinese.scopeTitle(.currentDayTodo), "当前 Day Todo")
        XCTAssertEqual(chinese.scopeTitle(.taskClassifications), "分组与标签")
        XCTAssertEqual(english.scopeTitle(.currentDayTodo), "Current Day Todo")
        XCTAssertEqual(english.scopeTitle(.taskClassifications), "Groups & Tags")

        for state in ZhulongSessionStateCopyKey.allCases {
            XCTAssertFalse(chinese.sessionStatus(state, style: .compact).isEmpty)
            let compact = english.sessionStatus(state, style: .compact)
            let expanded = english.sessionStatus(state, style: .expanded)
            XCTAssertFalse(compact.isEmpty)
            XCTAssertFalse(expanded.isEmpty)
            XCTAssertFalse(containsHan(compact), "Untranslated compact state: \(state)")
            XCTAssertFalse(containsHan(expanded), "Untranslated expanded state: \(state)")
        }
    }

    func testEveryEventKeyHasAnEnglishPresentationWithoutReplacingChineseAuditDetail() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong
        let chineseAuditTitle = "已原子应用 Todo diff，共 3 项"

        for key in ZhulongEventCopyKey.allCases {
            XCTAssertEqual(
                chinese.eventTitle(key, chineseAuditTitle: chineseAuditTitle),
                chineseAuditTitle
            )
            let title = english.eventTitle(key, chineseAuditTitle: chineseAuditTitle)
            XCTAssertFalse(title.isEmpty, "Missing event title: \(key)")
            XCTAssertFalse(containsHan(title), "Untranslated event title: \(key)")
        }
    }

    func testTypedNoticesAreBilingualAndCannotLeakUnderlyingErrors() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong
        let notices: [ZhulongWorkspaceNotice] = [
            .sessionCreationFailed,
            .todoBatchApplyFailed,
            .dailyReviewSaveFailed,
            .applicationRecoveryConflict,
            .applicationRecovered,
            .applicationRecoveryFailed,
            .applicationCommitRecoveryPending,
            .applicationCommitVerifiedComplete,
            .providerRunning,
            .providerRunFailed,
            .planningProviderRunning,
            .planningRunFailed,
            .memorySaveFailed,
            .unverifiableSessions(2),
            .memoryReadFailed,
            .sessionOperationFailed,
            .planningBriefSaveFailed
        ]
        let secret = "SECRET_PROVIDER_RESPONSE_OR_DATABASE_PATH"

        for notice in notices {
            let chineseText = chinese.notice(notice)
            let englishText = english.notice(notice)
            XCTAssertFalse(chineseText.isEmpty)
            XCTAssertFalse(englishText.isEmpty)
            XCTAssertFalse(containsHan(englishText), "Untranslated notice: \(notice)")
            XCTAssertFalse(chineseText.contains(secret))
            XCTAssertFalse(englishText.contains(secret))
        }
        XCTAssertEqual(english.notice(.unverifiableSessions(1)), "1 encrypted session could not be verified and was not loaded.")
        XCTAssertEqual(english.notice(.unverifiableSessions(2)), "2 encrypted sessions could not be verified and were not loaded.")
    }

    func testPendingApplicationMutationBlockedCopyIsBilingual() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong

        XCTAssertEqual(
            chinese.pendingApplicationMutationBlocked,
            "烛龙写入仍待恢复；完成恢复前无法修改任务。"
        )
        XCTAssertEqual(
            english.pendingApplicationMutationBlocked,
            "Finish recovering the interrupted Zhulong change before editing tasks."
        )
        XCTAssertFalse(containsHan(english.pendingApplicationMutationBlocked))
    }

    func testApplicationCommitNoticeProjectionPreservesDurableFacts() {
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .beforeEngine,
                recoveredCommitError: false,
                journal: .absent
            ),
            .failedBeforeCommit
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .beforeEngine,
                recoveredCommitError: false,
                journal: .presentOrUnverifiable
            ),
            .recoveryPending
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .enginePersistenceUnresolved,
                recoveredCommitError: false,
                journal: .presentOrUnverifiable
            ),
            .recoveryPending
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .enginePersisted,
                recoveredCommitError: false,
                journal: .presentOrUnverifiable
            ),
            .recoveryPending
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .sessionPersisted,
                recoveredCommitError: true,
                journal: .absent
            ),
            .verifiedCompletion
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .sessionPersisted,
                recoveredCommitError: true,
                journal: .presentOrUnverifiable
            ),
            .recoveryPending
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.state(
                progress: .completed,
                recoveredCommitError: true,
                journal: .absent
            ),
            .verifiedCompletion
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.mutationFailureNotice(
                fallback: .todoBatchApplyFailed,
                journal: .absent
            ),
            .todoBatchApplyFailed
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.mutationFailureNotice(
                fallback: .sessionOperationFailed,
                journal: .presentOrUnverifiable
            ),
            .applicationCommitRecoveryPending
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.mutationFailureNotice(
                fallback: .providerRunFailed,
                journal: .absent
            ),
            .providerRunFailed
        )
        XCTAssertNil(
            ZhulongApplicationCommitNoticeProjection
                .noticeAfterConfirmedAbsentJournal(
                    .applicationCommitRecoveryPending
                )
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection
                .noticeAfterConfirmedAbsentJournal(.providerRunFailed),
            .providerRunFailed
        )
        XCTAssertNil(
            ZhulongApplicationCommitNoticeProjection.notice(
                operation: .todoBatch,
                state: .cleanSuccess
            )
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.notice(
                operation: .todoBatch,
                state: .failedBeforeCommit
            ),
            .todoBatchApplyFailed
        )
        XCTAssertEqual(
            ZhulongApplicationCommitNoticeProjection.notice(
                operation: .dailyReview,
                state: .failedBeforeCommit
            ),
            .dailyReviewSaveFailed
        )
        for operation in ZhulongApplicationCommitOperation.allCases {
            XCTAssertEqual(
                ZhulongApplicationCommitNoticeProjection.notice(
                    operation: operation,
                    state: .recoveryPending
                ),
                .applicationCommitRecoveryPending
            )
            XCTAssertEqual(
                ZhulongApplicationCommitNoticeProjection.notice(
                    operation: operation,
                    state: .verifiedCompletion
                ),
                .applicationCommitVerifiedComplete
            )
        }
    }

    func testApplicationCommitNoticesStateNoChangePendingAndVerifiedCompletionExactly() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong

        XCTAssertEqual(
            chinese.notice(.todoBatchApplyFailed),
            "Todo 批次未能应用，未写入任何变更。"
        )
        XCTAssertEqual(
            english.notice(.todoBatchApplyFailed),
            "The Todo batch could not be applied. No changes were written."
        )
        XCTAssertEqual(
            chinese.notice(.dailyReviewSaveFailed),
            "每日复盘未能保存，未写入任何变更。"
        )
        XCTAssertEqual(
            english.notice(.dailyReviewSaveFailed),
            "The daily review could not be saved. No changes were written."
        )
        XCTAssertEqual(
            chinese.notice(.applicationCommitRecoveryPending),
            "烛龙原子写入尚未完整结束；后续写入已阻断，请先完成恢复。"
        )
        XCTAssertEqual(
            english.notice(.applicationCommitRecoveryPending),
            "The Zhulong atomic write has not fully completed. Further writes are blocked until recovery finishes."
        )
        XCTAssertEqual(
            chinese.notice(.applicationCommitVerifiedComplete),
            "烛龙写入曾返回错误，但系统已精确核对并完成提交；本次未显示普通成功提示。"
        )
        XCTAssertEqual(
            english.notice(.applicationCommitVerifiedComplete),
            "The Zhulong write returned an error, but its exact state was verified and the commit completed. The usual success confirmation was suppressed."
        )
    }

    func testTodoEditorAndProviderStatusCopyIsBilingual() {
        let chinese = AppPresentation(language: .chinese).zhulong
        let english = AppPresentation(language: .english).zhulong

        XCTAssertEqual(chinese.todoEditorTitle, "审查 Todo 变更")
        XCTAssertEqual(english.todoEditorTitle, "Review Todo changes")
        XCTAssertEqual(chinese.todoValidationMessage(.missingTitle), "任务标题不能为空。")
        XCTAssertEqual(english.todoValidationMessage(.missingTitle), "Task title cannot be empty.")
        XCTAssertEqual(chinese.todoTitlePart(1), "（部分 1）")
        XCTAssertEqual(english.todoTitlePart(2), " (Part 2)")
        XCTAssertEqual(chinese.providerStatus(.notConfigured), "未配置 Provider")
        XCTAssertEqual(english.providerStatus(.notConfigured), "Provider not configured")
        XCTAssertEqual(chinese.providerStatus(.savedWithCredential), "Provider 已保存，API Key 在 Keychain 中")
        XCTAssertEqual(english.providerStatus(.savedWithCredential), "Provider saved; API key is in Keychain")
        XCTAssertEqual(
            chinese.providerSettingsFailure(.keychainUnavailable),
            "无法访问 Keychain，请稍后再试。"
        )
        XCTAssertEqual(
            english.providerSettingsFailure(.keychainUnavailable),
            "Keychain could not be accessed. Try again shortly."
        )
        for notice in ZhulongProviderActionNotice.allCases {
            XCTAssertFalse(chinese.providerActionNotice(notice).isEmpty)
            XCTAssertFalse(containsHan(english.providerActionNotice(notice)))
        }
    }

    private func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400 ... 0x4DBF).contains(scalar.value) ||
                (0x4E00 ... 0x9FFF).contains(scalar.value)
        }
    }
}
