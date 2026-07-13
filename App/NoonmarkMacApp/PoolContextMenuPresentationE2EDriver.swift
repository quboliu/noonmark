import AppKit
import Foundation

@MainActor
enum PoolContextMenuPresentationE2EDriver {
    static func start(taskIdentifier: String, attemptsRemaining: Int = 80) {
        let identifier = PoolTaskRowE2ENamespace(
            taskIdentifier: taskIdentifier
        ).titleIdentifier
        guard let titleView = AppViewTreeE2E.view(identifier: identifier) else {
            guard attemptsRemaining > 1 else {
                NSLog("Noonmark pool context-menu E2E could not find %@", identifier)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                start(
                    taskIdentifier: taskIdentifier,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }
        guard AppViewTreeE2E.rightClick(titleView) else {
            NSLog("Noonmark pool context-menu E2E could not right-click %@", identifier)
            return
        }
    }

    static func selectScheduleToday(
        taskIdentifier: String,
        resultURL: URL,
        isScheduled: @escaping @MainActor () -> Bool,
        attemptsRemaining: Int = 80
    ) {
        let identifier = PoolTaskRowE2ENamespace(
            taskIdentifier: taskIdentifier
        ).titleIdentifier
        guard let titleView = AppViewTreeE2E.view(identifier: identifier) else {
            retryOrFinish(
                taskIdentifier: taskIdentifier,
                resultURL: resultURL,
                isScheduled: isScheduled,
                attemptsRemaining: attemptsRemaining,
                failure: "真实任务池行未出现"
            )
            return
        }
        guard AppViewTreeE2E.selectFirstContextMenuItem(of: titleView) else {
            finish("failed: 无法从真实任务行选择第一个右键动作", at: resultURL)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            waitForSchedule(
                resultURL: resultURL,
                isScheduled: isScheduled
            )
        }
    }

    private static func waitForSchedule(
        resultURL: URL,
        isScheduled: @escaping @MainActor () -> Bool,
        attemptsRemaining: Int = 60
    ) {
        guard isScheduled() else {
            guard attemptsRemaining > 1 else {
                finish("failed: 右键首项没有把任务排期到今天", at: resultURL)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                waitForSchedule(
                    resultURL: resultURL,
                    isScheduled: isScheduled,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }
        finish("ok", at: resultURL)
    }

    private static func retryOrFinish(
        taskIdentifier: String,
        resultURL: URL,
        isScheduled: @escaping @MainActor () -> Bool,
        attemptsRemaining: Int,
        failure: String
    ) {
        guard attemptsRemaining > 1 else {
            finish("failed: \(failure)", at: resultURL)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            selectScheduleToday(
                taskIdentifier: taskIdentifier,
                resultURL: resultURL,
                isScheduled: isScheduled,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private static func finish(_ result: String, at resultURL: URL) {
        if result != "ok" {
            AppViewTreeE2E.writeDump(beside: resultURL)
        }
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog(
                "Noonmark pool context-menu action E2E result write failed: %@",
                String(describing: error)
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
}
