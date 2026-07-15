extension AppCopy {
    // MARK: - Settings and Provider

    var organizationTitle: String { language == .chinese ? "组织" : "Organization" }
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

    var enableZhulong: String { language == .chinese ? "启用烛龙" : "Enable Zhulong" }
    var retainedKeychainCredentialPlaceholder: String {
        language == .chinese
            ? "Keychain 中已有凭证，留空则保留"
            : "Credential is stored in Keychain; leave blank to keep it"
    }

    var keychainOnlyPlaceholder: String {
        language == .chinese ? "只保存到 Keychain" : "Stored only in Keychain"
    }

    var localModel: String { language == .chinese ? "本地模型" : "Local model" }
    var customHTTP: String { language == .chinese ? "自定义 HTTP" : "Custom HTTP" }
    var baseURLLabel: String { "Base URL" }
    var apiKeyLabel: String { "API Key" }
}
