import Foundation
import NoonmarkAI
import NoonmarkStorage
import NoonmarkZhulong

struct ZhulongInlineArtifactE2EAutomation:
    LaunchAutomationRunnable
{
    let resultURL: URL
    let previewsDraft: Bool

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-zhulong-inline-artifact"
        ), let path = AppLaunchArguments.value(
            after: "--e2e-zhulong-inline-artifact-result-url"
        ) else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: path),
            previewsDraft: AppLaunchArguments.contains(
                "--e2e-zhulong-inline-artifact-preview"
            )
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        configureProvider(on: store)
        store.page = .zhulong
        store.startZhulongWorkspaceSession(
            intent: ZhulongChatE2EFixture.artifactIntent,
            task: .taskDecomposition
        )
        store.authorizeCurrentZhulongWorkspaceSession()
        waitForDraft(on: store, remainingAttempts: 120)
    }

    @MainActor
    private func configureProvider(on store: NoonmarkStore) {
        store.setZhulongPageEnabled(true)
        var draft = ZhulongProviderDraft()
        draft.displayName = "E2E inline artifact provider"
        draft.kind = .openAICompatible
        draft.baseURL = "https://e2e.provider.example/v1"
        draft.model = "e2e-inline-artifact-v1"
        draft.enabled = true
        draft.status = .savedWithCredential
        store.zhulongProviderDraft = draft
    }

    @MainActor
    private func waitForDraft(
        on store: NoonmarkStore,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            let session = store.zhulongWorkspace.selectedSession
            let lastSend = session?.providerSends.last
            AppViewTreeE2E.writeDump(beside: resultURL)
            write(
                [
                    "failed: inline task draft did not appear",
                    "phase=\(session?.phase.rawValue ?? "none")",
                    "workspaceStatus=\(session?.workspaceStatus.rawValue ?? "none")",
                    "providerFailure=\(lastSend?.failure?.code ?? "none")",
                    "response=\(lastSend?.response?.content ?? "none")",
                    "artifacts=\(lastSend?.response?.artifacts.count ?? -1)",
                    "drafts=\(session?.todoDiffDrafts.count ?? -1)",
                    "receipts=\(session?.todoApplyReceipts.count ?? -1)",
                    "currentDraft=\(session?.currentTodoDiff?.id.rawValue.uuidString ?? "none")",
                    "sessionStream=\(AppViewTreeE2E.view(identifier: "zhulong-session-stream") != nil)",
                    "notice=\(String(describing: store.zhulongWorkspace.status))"
                ].joined(separator: "; ")
            )
            return
        }
        guard let session = store.zhulongWorkspace.selectedSession,
              let draft = session.currentTodoDiff
              ?? session.latestTodoDiff
        else {
            retry {
                waitForDraft(
                    on: store,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        if session.applyReceipt(for: draft) != nil {
            waitForReceipt(
                on: store,
                draftID: draft.id,
                remainingAttempts: 80
            )
            return
        }
        guard draft.conversationRunID != nil,
              draft.items.count == 3,
              case let .createTask(
                  title,
                  _,
                  _,
                  subtasks,
                  targetDate
              ) = draft.items[0].operation,
              case let .createTask(
                  poolTitle,
                  _,
                  _,
                  poolSubtasks,
                  poolTargetDate
              ) = draft.items[1].operation,
              case let .createTask(
                  futureTitle,
                  _,
                  _,
                  futureSubtasks,
                  futureTargetDate
              ) = draft.items[2].operation
        else {
            write(
                "failed: inline task draft origin or item count diverged"
            )
            return
        }
        guard title == ZhulongChatE2EFixture.artifactTaskTitle,
              subtasks.map(\.title)
              == ZhulongChatE2EFixture.artifactSubtaskTitles,
              targetDate == store.today,
              poolTitle
              == ZhulongChatE2EFixture.artifactPoolTaskTitle,
              poolSubtasks.isEmpty,
              poolTargetDate == nil,
              futureTitle
              == ZhulongChatE2EFixture.artifactFutureTaskTitle,
              futureSubtasks.isEmpty,
              futureTargetDate
              == ZhulongChatE2EFixture.artifactFutureDate
        else {
            write(
                "failed: inline task fields diverged: title=\(title), subtasks=\(subtasks.map(\.title)), target=\(targetDate?.description ?? "pool"), pool=\(poolTitle), future=\(futureTitle), futureDate=\(futureTargetDate?.description ?? "none"), today=\(store.today)"
            )
            return
        }
        guard AppViewTreeE2E.view(
            identifier: "zhulong-inline-task-draft-anchor"
        ) != nil,
            let submitAnchor = AppViewTreeE2E.view(
                identifier:
                "zhulong-inline-task-draft-submit-anchor"
            ),
            let submitButton = AppViewTreeE2E.button(
                overlapping: submitAnchor
            )
        else {
            retry {
                waitForDraft(
                    on: store,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        if previewsDraft {
            writePreviewReady()
            return
        }
        guard AppViewTreeE2E.click(submitButton) else {
            retry {
                waitForDraft(
                    on: store,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        waitForReceipt(
            on: store,
            draftID: draft.id,
            remainingAttempts: 80
        )
    }

    @MainActor
    private func waitForReceipt(
        on store: NoonmarkStore,
        draftID: ZhulongTodoDiffID,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            write("failed: inline task draft was not applied")
            return
        }
        let session = store.zhulongWorkspace.selectedSession
        let applied = session?.todoApplyReceipts.contains {
            $0.draftID == draftID
        } == true
        guard let databaseURL = store.databaseURL,
              let persistedEngine = try? SQLiteEngineRepository(
                  databaseURL: databaseURL
              ).load()
        else {
            write("failed: persisted engine could not be loaded")
            return
        }
        let visibleTask = persistedEngine.getDayTodo(
            date: store.today
        ).traces.contains { trace in
            persistedEngine.definitions[trace.definitionID]?.title
                == ZhulongChatE2EFixture.artifactTaskTitle
        }
        let pooledTask = persistedEngine.taskPool().contains {
            $0.definition.title
                == ZhulongChatE2EFixture.artifactPoolTaskTitle
        }
        let futureTask = persistedEngine.futurePlans(
            today: store.today
        ).contains {
            $0.definition.title
                == ZhulongChatE2EFixture.artifactFutureTaskTitle
                && $0.trace.date
                == ZhulongChatE2EFixture.artifactFutureDate
        }
        let actionDismissed = AppViewTreeE2E.hasNoVisibleView(
            identifier:
            "zhulong-stream-conversation-current-action"
        )
        guard applied,
              visibleTask,
              pooledTask,
              futureTask,
              actionDismissed
        else {
            retry {
                waitForReceipt(
                    on: store,
                    draftID: draftID,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        write("ok")
    }

    @MainActor
    private func retry(_ operation: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05
        ) {
            operation()
        }
    }

    @MainActor
    private func write(_ result: String) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(
                to: resultURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog(
                "Noonmark inline artifact E2E result failed: %@",
                String(describing: error)
            )
        }
        E2EApplicationTermination.schedule()
    }

    private func writePreviewReady() {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "ready".write(
                to: resultURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog(
                "Noonmark inline artifact preview failed: %@",
                String(describing: error)
            )
        }
    }
}
