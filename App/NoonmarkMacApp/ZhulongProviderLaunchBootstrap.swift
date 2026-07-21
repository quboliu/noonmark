import Foundation
import NoonmarkAI

enum ZhulongProviderLaunchBootstrap {
    private static let requestEnvironmentKey = "NOONMARK_BOOTSTRAP_PROVIDER"
    private static let exitAfterBootstrapEnvironmentKey = "NOONMARK_BOOTSTRAP_PROVIDER_ONLY"
    private static let baseURLEnvironmentKey = "NOONMARK_AI_BASE_URL"
    private static let modelEnvironmentKey = "NOONMARK_AI_MODEL"
    private static let apiKeyEnvironmentKey = "NOONMARK_AI_API_KEY"
    private static let readinessResultPathEnvironmentKey = "NOONMARK_PROVIDER_READINESS_RESULT_PATH"

    /// Imports an explicitly supplied developer Provider configuration before the
    /// interactive app is shown. The API key is handed directly to the Keychain
    /// writer and is never copied into UserDefaults or a view-model draft.
    static func applyIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard environment[requestEnvironmentKey] == "1" else {
            if environment[exitAfterBootstrapEnvironmentKey] == "1" {
                throw ZhulongProviderLaunchBootstrapError.exitRequestedWithoutBootstrap
            }
            return false
        }

        guard let baseURL = nonEmptyValue(for: baseURLEnvironmentKey, in: environment),
              let model = nonEmptyValue(for: modelEnvironmentKey, in: environment),
              let apiKey = nonEmptyValue(for: apiKeyEnvironmentKey, in: environment)
        else {
            throw ZhulongProviderLaunchBootstrapError.incompleteConfiguration
        }

        var draft = ZhulongProviderSettingsStore.load()
        draft.displayName = displayName(for: baseURL)
        draft.kind = .openAICompatible
        draft.baseURL = baseURL
        draft.model = model
        draft.apiKeyInput = apiKey
        draft.enabled = true

        _ = try ZhulongProviderSettingsStore.save(draft)
        UserDefaults.standard.synchronize()
        return true
    }

    static func exitsAfterBootstrap(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[exitAfterBootstrapEnvironmentKey] == "1"
    }

    /// A non-interactive launch probe used by the development launcher. It
    /// reads the exact persisted settings that the GUI store will bind to and
    /// reports readiness without exposing a credential or starting a window.
    @discardableResult
    static func reportPersistedReadinessIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard let path = nonEmptyValue(
            for: readinessResultPathEnvironmentKey,
            in: environment
        ) else { return false }
        let resultURL = URL(fileURLWithPath: path)
        let ready = ZhulongProviderSettingsStore.persistedReadyExecutionRevision() != nil
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (ready ? "ready" : "not-ready").write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
        return true
    }

    private static func nonEmptyValue(
        for key: String,
        in environment: [String: String]
    ) -> String? {
        guard let value = environment[key],
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return value
    }

    private static func displayName(for baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host,
              let firstComponent = host.split(separator: ".").first,
              firstComponent.isEmpty == false
        else {
            return "Zhulong Provider"
        }
        return String(firstComponent).capitalized
    }
}

enum ZhulongProviderLaunchBootstrapError: LocalizedError {
    case incompleteConfiguration
    case exitRequestedWithoutBootstrap

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            "Provider bootstrap requires NOONMARK_AI_BASE_URL, NOONMARK_AI_MODEL, and NOONMARK_AI_API_KEY."
        case .exitRequestedWithoutBootstrap:
            "Provider bootstrap-only launch requires NOONMARK_BOOTSTRAP_PROVIDER=1."
        }
    }
}
