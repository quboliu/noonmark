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
        guard trimmed.isEmpty == false,
              let url = URL(string: trimmed),
              ZhulongProviderEndpointPolicy.permits(url)
        else {
            return nil
        }
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
        let stored = storedConfig()
        if let stored {
            try? ZhulongProviderKeychain.removeCredentials(
                except: stored.executionRevision
            )
            draft.displayName = stored.displayName
            draft.kind = stored.kind
            draft.baseURL = stored.baseURL.absoluteString
            draft.model = stored.model
            draft.enabled = stored.enabled
            draft.hasStoredAPIKey = ZhulongProviderKeychain.hasAPIKey(
                for: stored.executionRevision
            )
        }
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
                  hasCredential: try ZhulongProviderKeychain.readAPIKey(
                      for: stored.executionRevision
                  )?.isEmpty == false
              )
        else { return nil }
        return stored.executionRevision
    }

    static func persistedConfiguredExecutionRevision() -> UUID? {
        guard let stored = storedConfig(),
              stored.enabled,
              stored.kind == .openAICompatible,
              stored.model.isEmpty == false,
              ZhulongProviderEndpointPolicy.permits(stored.baseURL)
        else { return nil }
        return stored.executionRevision
    }

    static func makePersistedConfig(
        expectedExecutionRevision: UUID? = nil
    ) throws -> AIProviderConfig? {
        guard let stored = storedConfig(),
              expectedExecutionRevision == nil
              || stored.executionRevision == expectedExecutionRevision,
              readiness(
                  config: stored,
                  hasCredential: try ZhulongProviderKeychain.readAPIKey(
                      for: stored.executionRevision
                  )?.isEmpty == false
              )
        else { return nil }
        return AIProviderConfig(
            providerID: AIProviderID("default"),
            displayName: stored.displayName,
            kind: stored.kind,
            baseURL: stored.baseURL,
            model: stored.model,
            apiKeyRef: ZhulongProviderKeychain.keyRef(
                for: stored.executionRevision
            ),
            enabled: stored.enabled
        )
    }

    static func save(
        _ draft: ZhulongProviderDraft,
        afterCredentialWriteBeforeConfigPointer: ((UUID) throws -> Void)? = nil,
        afterConfigPointerPublication: ((UUID) throws -> Void)? = nil
    ) throws -> ZhulongProviderSettingsTransition {
        guard draft.enabled == false || draft.normalizedBaseURL != nil else {
            throw ZhulongProviderSettingsError.invalidBaseURL
        }
        guard draft.enabled == false || draft.normalizedModel.isEmpty == false else {
            throw ZhulongProviderSettingsError.emptyModel
        }
        let baseURL = draft.normalizedBaseURL ?? URL(string: "https://api.example.com/v1")!
        let previous = storedConfig()
        let previousAPIKey = try previous.flatMap {
            try ZhulongProviderKeychain.readAPIKey(for: $0.executionRevision)
        }
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

        let executionRevision = executionChanged
            ? UUID()
            : previous?.executionRevision ?? UUID()
        let stored = StoredZhulongProviderConfig(
            displayName: draft.normalizedDisplayName,
            kind: draft.kind,
            baseURL: baseURL,
            model: draft.normalizedModel,
            enabled: draft.enabled,
            executionRevision: executionRevision
        )
        let data = try JSONEncoder().encode(stored)

        if executionChanged, let currentAPIKey, currentAPIKey.isEmpty == false {
            try ZhulongProviderKeychain.saveAPIKey(
                currentAPIKey,
                for: executionRevision
            )
            try afterCredentialWriteBeforeConfigPointer?(executionRevision)
        }
        if stored != previous {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            guard UserDefaults.standard.data(forKey: defaultsKey) == data else {
                throw ZhulongProviderSettingsError.configPointerFailure
            }
        }
        try afterConfigPointerPublication?(executionRevision)

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

    static func clear(
        afterCredentialRemovalBeforeConfigPointer: (() throws -> Void)? = nil
    ) throws -> ZhulongProviderSettingsTransition {
        let previous = storedConfig()
        let previousAPIKey = try previous.flatMap {
            try ZhulongProviderKeychain.readAPIKey(for: $0.executionRevision)
        }
        try ZhulongProviderKeychain.removeCredentials(except: nil)
        try afterCredentialRemovalBeforeConfigPointer?()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        guard UserDefaults.standard.data(forKey: defaultsKey) == nil else {
            throw ZhulongProviderSettingsError.configPointerFailure
        }
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
              ZhulongProviderEndpointPolicy.permits(config.baseURL)
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
        let keyRef: String? = if draft.hasStoredAPIKey,
                                 let stored = storedConfig(),
                                 stored.kind == draft.kind,
                                 stored.baseURL == baseURL,
                                 stored.model == draft.normalizedModel,
                                 try ZhulongProviderKeychain.readAPIKey(
                                     for: stored.executionRevision
                                 )?.isEmpty == false
        {
            ZhulongProviderKeychain.keyRef(for: stored.executionRevision)
        } else {
            nil
        }
        return AIProviderConfig(
            providerID: AIProviderID("default"),
            displayName: draft.normalizedDisplayName,
            kind: draft.kind,
            baseURL: baseURL,
            model: draft.normalizedModel,
            apiKeyRef: keyRef,
            enabled: draft.enabled
        )
    }
}

private enum ZhulongProviderEndpointPolicy {
    static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(),
              let decodedHost = rawHost.removingPercentEncoding
        else { return false }
        let host = decodedHost.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        guard host.isEmpty == false else { return false }
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

enum ZhulongProviderSettingsError: Error, Equatable {
    case invalidBaseURL
    case emptyModel
    case configPointerFailure
    case keychainFailure(OSStatus)

    var presentationFailure: ZhulongProviderSettingsFailure {
        switch self {
        case .invalidBaseURL:
            .invalidBaseURL
        case .emptyModel:
            .emptyModel
        case .keychainFailure:
            .keychainUnavailable
        case .configPointerFailure:
            .unexpected
        }
    }
}

enum ZhulongProviderKeychain {
    private static let keyRefPrefix = "keychain:noonmark.zhulong.execution:"
    private static let accountPrefix = "execution-"
    private static let accountSuffix = "-api-key"

    static var serviceIdentifier: String {
        Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e"
            ? "app.noonmark.zhulong.provider.e2e"
            : "app.noonmark.zhulong.provider"
    }

    static func keyRef(for executionRevision: UUID) -> String {
        keyRefPrefix + executionRevision.uuidString.lowercased()
    }

    static func hasAPIKey(for executionRevision: UUID) -> Bool {
        (try? readAPIKey(for: executionRevision))?.isEmpty == false
    }

    static func hasAnyAPIKey() throws -> Bool {
        try credentialAccounts().isEmpty == false
    }

    static func resolveAPIKey(
        _ keyRef: String,
        expectedExecutionRevision: UUID? = nil
    ) throws -> String? {
        guard let executionRevision = executionRevision(from: keyRef),
              expectedExecutionRevision == nil
              || executionRevision == expectedExecutionRevision
        else { return nil }
        return try readAPIKey(for: executionRevision)
    }

    static func readAPIKey(for executionRevision: UUID) throws -> String? {
        var query = credentialQuery(for: executionRevision)
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

    static func saveAPIKey(
        _ apiKey: String,
        for executionRevision: UUID
    ) throws {
        let data = Data(apiKey.utf8)
        var query = credentialQuery(for: executionRevision)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem,
           try readAPIKey(for: executionRevision) == apiKey
        {
            return
        }
        guard status == errSecSuccess else {
            throw ZhulongProviderSettingsError.keychainFailure(status)
        }
    }

    static func removeCredentials(except activeExecutionRevision: UUID?) throws {
        let activeAccount = activeExecutionRevision.map(account(for:))
        for account in try credentialAccounts() where account != activeAccount {
            let status = SecItemDelete(
                serviceQuery(account: account) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ZhulongProviderSettingsError.keychainFailure(status)
            }
        }
    }

    private static func executionRevision(from keyRef: String) -> UUID? {
        guard keyRef.hasPrefix(keyRefPrefix),
              let revision = UUID(
                  uuidString: String(keyRef.dropFirst(keyRefPrefix.count))
              ),
              keyRef == self.keyRef(for: revision)
        else { return nil }
        return revision
    }

    private static func credentialAccounts() throws -> [String] {
        var query = serviceQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw ZhulongProviderSettingsError.keychainFailure(status)
        }
        let dictionaries: [[String: Any]] = if let values = items as? [[String: Any]] {
            values
        } else if let value = items as? [String: Any] {
            [value]
        } else {
            []
        }
        return dictionaries.compactMap {
            $0[kSecAttrAccount as String] as? String
        }
    }

    private static func credentialQuery(
        for executionRevision: UUID
    ) -> [String: Any] {
        serviceQuery(account: account(for: executionRevision))
    }

    private static func account(for executionRevision: UUID) -> String {
        accountPrefix + executionRevision.uuidString.lowercased() + accountSuffix
    }

    private static func serviceQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}
