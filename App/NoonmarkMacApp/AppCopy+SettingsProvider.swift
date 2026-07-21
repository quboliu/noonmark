import NoonmarkStorage

extension AppCopy {
    // MARK: - Settings and Provider

    var organizationTitle: String { language == .chinese ? "组织" : "Organisation" }
    var chineseLanguage: String { language == .chinese ? "中文" : "Chinese" }
    var englishLanguage: String { "English" }
    var settingsPoemPlaceholder: String {
        language == .chinese ? "输入诗文或 Markdown" : "Enter a poem or Markdown"
    }

    var settingsPoemName: String {
        language == .chinese ? "苦昼短" : "Song of the Short Day"
    }

    var iCloudDriveUnavailable: String {
        language == .chinese ? "iCloud Drive 不可用" : "iCloud Drive unavailable"
    }

    var enableZhulongPage: String {
        language == .chinese ? "显示烛龙页面" : "Show Zhulong page"
    }

    var zhulongPageSwitchDescription: String {
        language == .chinese
            ? "只控制导航和会话入口，不影响自动归类或 Provider。"
            : "Controls navigation and session entry only; automation and the Provider are unaffected."
    }

    var enableAutomaticClassification: String {
        language == .chinese ? "自动生成分组与标签" : "Automatic groups and labels"
    }

    var automaticClassificationSwitchDescription: String {
        language == .chinese
            ? "关闭后不再为新任务入队并停止 worker；已有结果和作业记录会保留。"
            : "Stops new jobs and the worker while preserving existing results and job history."
    }

    var enableProvider: String {
        language == .chinese ? "启用 Provider" : "Enable Provider"
    }

    var zhulongFeaturesTitle: String {
        language == .chinese ? "功能" : "Features"
    }

    var providerConfigurationTitle: String {
        language == .chinese ? "Provider" : "Provider"
    }

    var apiKeyPlaceholder: String {
        language == .chinese ? "输入 API Key" : "Enter API key"
    }

    var localModel: String { language == .chinese ? "本地模型" : "Local model" }
    var customHTTP: String { language == .chinese ? "自定义 HTTP" : "Custom HTTP" }
    var baseURLLabel: String { "Base URL" }
    var apiKeyLabel: String { "API Key" }

    func automaticClassificationBacklogTitle(_ count: Int) -> String {
        switch language {
        case .chinese:
            "\(count) 项历史任务等待智能归类"
        case .english:
            count == 1
                ? "1 earlier task is waiting to be organized"
                : "\(count) earlier tasks are waiting to be organized"
        }
    }

    var automaticClassificationBacklogExplanation: String {
        language == .chinese
            ? "这些任务是在 AI 不可用时创建的。等待期间已手动调整分组或标签的任务不会处理。"
            : "These tasks were created while AI was unavailable. Tasks organized manually while waiting will not be processed."
    }

    func startAutomaticClassificationBacklog(_ count: Int) -> String {
        switch language {
        case .chinese:
            "开始 \(count) 项"
        case .english:
            count == 1 ? "Start 1 task" : "Start \(count) tasks"
        }
    }

    var classifyOnlyFutureTasks: String {
        language == .chinese ? "仅处理今后新任务" : "Only new tasks"
    }

    var decideAutomaticClassificationBacklogLater: String {
        language == .chinese ? "稍后" : "Later"
    }

    func automaticClassificationBacklogAccessibilityValue(
        _ count: Int
    ) -> String {
        switch language {
        case .chinese:
            "等待 \(count) 项"
        case .english:
            count == 1 ? "1 task waiting" : "\(count) tasks waiting"
        }
    }

    func startAutomaticClassificationBacklogAccessibilityLabel(
        _ count: Int
    ) -> String {
        switch language {
        case .chinese:
            "开始处理 \(count) 项历史任务"
        case .english:
            count == 1
                ? "Start organizing 1 earlier task"
                : "Start organizing \(count) earlier tasks"
        }
    }

    func classifyOnlyFutureTasksAccessibilityLabel(_ count: Int) -> String {
        switch language {
        case .chinese:
            "跳过 \(count) 项历史任务，仅自动归类今后新任务"
        case .english:
            count == 1
                ? "Skip 1 earlier task and organize only new tasks"
                : "Skip \(count) earlier tasks and organize only new tasks"
        }
    }

    func decideAutomaticClassificationBacklogLaterAccessibilityLabel(
        _ count: Int
    ) -> String {
        switch language {
        case .chinese:
            "稍后决定，\(count) 项历史任务继续等待"
        case .english:
            count == 1
                ? "Decide later and keep 1 earlier task waiting"
                : "Decide later and keep \(count) earlier tasks waiting"
        }
    }

    var automaticClassificationPaused: String {
        language == .chinese ? "智能归类已暂停" : "Organizing paused"
    }

    var retryAutomaticClassificationProvider: String {
        language == .chinese ? "重新尝试" : "Try again"
    }

    var automaticClassificationPausedRetry: String {
        language == .chinese
            ? "智能归类已暂停 · 重试"
            : "Organizing paused · Retry"
    }

    func automaticClassificationCircuitMessage(
        _ count: Int,
        failureCode: AutomaticClassificationJobErrorCode
    ) -> String {
        switch language {
        case .chinese:
            if failureCode == .providerRejected {
                return "Provider 拒绝了当前凭证或配置，已停止自动请求；\(count) 项任务保留在本机。请检查 API Key、Base URL 与模型后保存。"
            }
            if failureCode == .providerRateLimited {
                return "Provider 持续限流，已停止自动请求；\(count) 项任务保留在本机。重新尝试后可继续。"
            }
            return "Provider 连续不可用，已停止自动请求；\(count) 项任务保留在本机。重新尝试后可继续。"
        case .english:
            let tasks = count == 1 ? "1 task is" : "\(count) tasks are"
            if failureCode == .providerRejected {
                return "The Provider rejected the current credential or configuration. Automatic requests have stopped, and \(tasks) safely kept on this Mac. Check the API key, Base URL, and model, then save."
            }
            if failureCode == .providerRateLimited {
                return "The Provider keeps rate-limiting requests. Automatic requests have stopped, and \(tasks) safely kept on this Mac. Try again to continue."
            }
            return "The Provider remains unavailable, so automatic requests have stopped. \(tasks) safely kept on this Mac. Try again to continue."
        }
    }
}
