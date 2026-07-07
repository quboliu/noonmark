import Foundation
import Security
import SuntraceAI

struct ZhulongProviderDraft: Equatable {
    var displayName = ""
    var kind: AIProviderKind = .openAICompatible
    var baseURL = "https://api.example.com/v1"
    var model = ""
    var apiKeyInput = ""
    var enabled = false
    var hasStoredAPIKey = false
    var statusMessage = "未配置 Provider"

    var isConfigured: Bool {
        enabled
            && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && normalizedBaseURL != nil
    }

    var normalizedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var normalizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "自定义 Provider" : trimmed
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct StoredZhulongProviderConfig: Codable, Equatable {
    var displayName: String
    var kind: AIProviderKind
    var baseURL: URL
    var model: String
    var enabled: Bool
}

enum ZhulongProviderSettingsStore {
    private static let defaultsKey = "suntrace.zhulong.provider.config"

    static func load() -> ZhulongProviderDraft {
        var draft = ZhulongProviderDraft()
        if let stored = storedConfig() {
            draft.displayName = stored.displayName
            draft.kind = stored.kind
            draft.baseURL = stored.baseURL.absoluteString
            draft.model = stored.model
            draft.enabled = stored.enabled
        }
        draft.hasStoredAPIKey = ZhulongProviderKeychain.hasAPIKey()
        if draft.enabled {
            draft.statusMessage = draft.hasStoredAPIKey ? "Provider 已保存，API Key 在 Keychain 中" : "Provider 已保存，未保存 API Key"
        }
        return draft
    }

    private static func storedConfig() -> StoredZhulongProviderConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(StoredZhulongProviderConfig.self, from: data)
    }

    static func save(_ draft: ZhulongProviderDraft) throws -> ZhulongProviderDraft {
        guard draft.enabled == false || draft.normalizedBaseURL != nil else {
            throw ZhulongProviderSettingsError.invalidBaseURL
        }
        guard draft.enabled == false || draft.normalizedModel.isEmpty == false else {
            throw ZhulongProviderSettingsError.emptyModel
        }
        let baseURL = draft.normalizedBaseURL ?? URL(string: "https://api.example.com/v1")!

        let stored = StoredZhulongProviderConfig(
            displayName: draft.normalizedDisplayName,
            kind: draft.kind,
            baseURL: baseURL,
            model: draft.normalizedModel,
            enabled: draft.enabled
        )
        let data = try JSONEncoder().encode(stored)
        UserDefaults.standard.set(data, forKey: defaultsKey)

        var next = draft
        next.displayName = stored.displayName
        next.baseURL = stored.baseURL.absoluteString
        next.model = stored.model
        if draft.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try ZhulongProviderKeychain.saveAPIKey(draft.apiKeyInput)
            next.apiKeyInput = ""
        }
        next.hasStoredAPIKey = ZhulongProviderKeychain.hasAPIKey()
        if next.enabled {
            next.statusMessage = next.hasStoredAPIKey ? "Provider 已保存，API Key 在 Keychain 中" : "Provider 已保存，未保存 API Key"
        } else {
            next.statusMessage = "烛龙已关闭，普通清单不受影响"
        }
        return next
    }

    static func clear() throws -> ZhulongProviderDraft {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        try ZhulongProviderKeychain.deleteAPIKey()
        return ZhulongProviderDraft()
    }

    static func makeConfig(from draft: ZhulongProviderDraft) throws -> AIProviderConfig {
        guard let baseURL = draft.normalizedBaseURL else {
            throw ZhulongProviderSettingsError.invalidBaseURL
        }
        guard draft.normalizedModel.isEmpty == false else {
            throw ZhulongProviderSettingsError.emptyModel
        }
        return AIProviderConfig(
            providerID: AIProviderID("default"),
            displayName: draft.normalizedDisplayName,
            kind: draft.kind,
            baseURL: baseURL,
            model: draft.normalizedModel,
            apiKeyRef: draft.hasStoredAPIKey ? ZhulongProviderKeychain.keyRef : nil,
            enabled: draft.enabled
        )
    }
}

enum ZhulongProviderSettingsError: LocalizedError, Equatable {
    case invalidBaseURL
    case emptyModel
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Base URL 必须是 http 或 https URL"
        case .emptyModel:
            return "模型名称不能为空"
        case let .keychainFailure(status):
            return "Keychain 操作失败：\(status)"
        }
    }
}

enum ZhulongProviderKeychain {
    static let keyRef = "keychain:suntrace.zhulong.default"
    private static let service = "app.suntrace.zhulong.provider"
    private static let account = "default-api-key"

    static func hasAPIKey() -> Bool {
        (try? readAPIKey())?.isEmpty == false
    }

    static func readAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ZhulongProviderSettingsError.keychainFailure(status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ZhulongProviderSettingsError.keychainFailure(status)
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZhulongProviderSettingsError.keychainFailure(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
