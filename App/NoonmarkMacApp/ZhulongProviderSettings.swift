import Foundation
import NoonmarkAI
import NoonmarkMacRuntime
import Security

struct ZhulongProviderDraft: Equatable {
    var displayName = ""
    var kind: AIProviderKind = .openAICompatible
    var baseURL = "https://api.example.com/v1"
    var model = ""
    var apiKeyInput = ""
    var enabled = false
    var hasStoredAPIKey = false
    var status: ZhulongProviderStatus = .notConfigured

    var statusMessage: String {
        AppPresentation(language: .chinese).zhulong.providerStatus(status)
    }

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
        return trimmed.isEmpty
            ? AppPresentation(language: .chinese).zhulong.customProviderName
            : trimmed
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
    var executionRevision: UUID
}

struct ZhulongProviderSettingsTransition: Equatable {
    let draft: ZhulongProviderDraft
    let previousExecutionRevision: UUID?
    let currentExecutionRevision: UUID?
    let previousReadiness: Bool
    let currentReadiness: Bool

    var revisionChanged: Bool {
        previousExecutionRevision != currentExecutionRevision
    }

    var readinessChanged: Bool {
        previousReadiness != currentReadiness
    }
}

enum ZhulongProviderSettingsStore {
    private static let defaultsKey = "noonmark.zhulong.provider.config"

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
            draft.status = draft.hasStoredAPIKey ? .savedWithCredential : .savedWithoutCredential
        }
        return draft
    }

    private static func storedConfig() -> StoredZhulongProviderConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(StoredZhulongProviderConfig.self, from: data)
    }

    static func persistedReadyExecutionRevision() -> UUID? {
        try? readPersistedReadyExecutionRevision()
    }

    static func readPersistedReadyExecutionRevision() throws -> UUID? {
        guard let stored = storedConfig(),
              readiness(
                  config: stored,
                  hasCredential: try ZhulongProviderKeychain.readAPIKey()?.isEmpty == false
              )
        else { return nil }
        return stored.executionRevision
    }

    static func persistedConfiguredExecutionRevision() -> UUID? {
        guard let stored = storedConfig(),
              stored.enabled,
              stored.kind == .openAICompatible,
              stored.model.isEmpty == false,
              let scheme = stored.baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return stored.executionRevision
    }

    static func makePersistedConfig() throws -> AIProviderConfig? {
        guard let stored = storedConfig(),
              readiness(
                  config: stored,
                  hasCredential: try ZhulongProviderKeychain.readAPIKey()?.isEmpty == false
              )
        else { return nil }
        return AIProviderConfig(
            providerID: AIProviderID("default"),
            displayName: stored.displayName,
            kind: stored.kind,
            baseURL: stored.baseURL,
            model: stored.model,
            apiKeyRef: ZhulongProviderKeychain.keyRef,
            enabled: stored.enabled
        )
    }

    static func save(
        _ draft: ZhulongProviderDraft
    ) throws -> ZhulongProviderSettingsTransition {
        guard draft.enabled == false || draft.normalizedBaseURL != nil else {
            throw ZhulongProviderSettingsError.invalidBaseURL
        }
        guard draft.enabled == false || draft.normalizedModel.isEmpty == false else {
            throw ZhulongProviderSettingsError.emptyModel
        }
        let baseURL = draft.normalizedBaseURL ?? URL(string: "https://api.example.com/v1")!
        let previous = storedConfig()
        let previousAPIKey = try ZhulongProviderKeychain.readAPIKey()
        let submittedAPIKey = draft.apiKeyInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? nil
            : draft.apiKeyInput
        let currentAPIKey = submittedAPIKey ?? previousAPIKey
        let executionChanged = previous == nil
            || previous?.kind != draft.kind
            || previous?.baseURL != baseURL
            || previous?.model != draft.normalizedModel
            || submittedAPIKey.map { $0 != previousAPIKey } == true

        let stored = StoredZhulongProviderConfig(
            displayName: draft.normalizedDisplayName,
            kind: draft.kind,
            baseURL: baseURL,
            model: draft.normalizedModel,
            enabled: draft.enabled,
            executionRevision: executionChanged
                ? UUID()
                : previous?.executionRevision ?? UUID()
        )
        let data = try JSONEncoder().encode(stored)

        if let submittedAPIKey, submittedAPIKey != previousAPIKey {
            try ZhulongProviderKeychain.saveAPIKey(submittedAPIKey)
        }
        if stored != previous {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }

        var next = draft
        next.displayName = stored.displayName
        next.baseURL = stored.baseURL.absoluteString
        next.model = stored.model
        next.apiKeyInput = ""
        next.hasStoredAPIKey = currentAPIKey?.isEmpty == false
        if next.enabled {
            next.status = next.hasStoredAPIKey ? .savedWithCredential : .savedWithoutCredential
        } else {
            next.status = .disabled
        }
        return ZhulongProviderSettingsTransition(
            draft: next,
            previousExecutionRevision: previous?.executionRevision,
            currentExecutionRevision: stored.executionRevision,
            previousReadiness: readiness(
                config: previous,
                hasCredential: previousAPIKey?.isEmpty == false
            ),
            currentReadiness: readiness(
                config: stored,
                hasCredential: currentAPIKey?.isEmpty == false
            )
        )
    }

    static func clear() throws -> ZhulongProviderSettingsTransition {
        let previous = storedConfig()
        let previousAPIKey = try ZhulongProviderKeychain.readAPIKey()
        try ZhulongProviderKeychain.deleteAPIKey()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return ZhulongProviderSettingsTransition(
            draft: ZhulongProviderDraft(),
            previousExecutionRevision: previous?.executionRevision,
            currentExecutionRevision: nil,
            previousReadiness: readiness(
                config: previous,
                hasCredential: previousAPIKey?.isEmpty == false
            ),
            currentReadiness: false
        )
    }

    private static func readiness(
        config: StoredZhulongProviderConfig?,
        hasCredential: Bool
    ) -> Bool {
        guard let config,
              config.enabled,
              config.kind == .openAICompatible,
              config.model.isEmpty == false,
              let scheme = config.baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return hasCredential
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

enum ZhulongProviderSettingsError: Error, Equatable {
    case invalidBaseURL
    case emptyModel
    case keychainFailure(OSStatus)

    var presentationFailure: ZhulongProviderSettingsFailure {
        switch self {
        case .invalidBaseURL:
            .invalidBaseURL
        case .emptyModel:
            .emptyModel
        case .keychainFailure:
            .keychainUnavailable
        }
    }
}

enum ZhulongProviderKeychain {
    static let keyRef = "keychain:noonmark.zhulong.default"
    static var serviceIdentifier: String {
        Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e"
            ? "app.noonmark.zhulong.provider.e2e"
            : "app.noonmark.zhulong.provider"
    }

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
        let query = baseQuery()
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    query as CFDictionary,
                    attributes as CFDictionary
                )
            }
        }
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
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: account
        ]
    }
}
