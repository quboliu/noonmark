import Foundation
import NoonmarkAI

private enum LiveSmokeError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case invalidDeepSeekBaseURL
    case providerUnavailable
    case providerRequestFailed
    case invalidClassificationProposal

    var description: String {
        switch self {
        case let .missingEnvironment(name):
            "missing required environment variable: \(name)"
        case .invalidDeepSeekBaseURL:
            "live AI tests only accept https://api.deepseek.com or its /v1 compatibility path"
        case .providerUnavailable:
            "DeepSeek health check did not succeed"
        case .providerRequestFailed:
            "DeepSeek completion request did not succeed"
        case .invalidClassificationProposal:
            "DeepSeek returned an invalid automatic-classification proposal"
        }
    }
}

@main
private struct NoonmarkAIProviderLiveSmoke {
    static func main() async {
        do {
            let labelCount = try await run()
            print(
                "DeepSeek live automatic-classification contract passed "
                    + "(one category, \(labelCount) labels)."
            )
        } catch let error as LiveSmokeError {
            fputs("DeepSeek live automatic-classification contract failed: \(error)\n", stderr)
            exit(1)
        } catch {
            fputs("DeepSeek live automatic-classification contract failed: internal error\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws -> Int {
        let environment = ProcessInfo.processInfo.environment
        let baseURLText = try required("NOONMARK_AI_BASE_URL", in: environment)
        let model = try required("NOONMARK_AI_MODEL", in: environment)
        let apiKey = try required("NOONMARK_AI_API_KEY", in: environment)
        guard let baseURL = URL(string: baseURLText),
              baseURL.scheme == "https",
              baseURL.host == "api.deepseek.com",
              ["", "/", "/v1", "/v1/"].contains(baseURL.path)
        else {
            throw LiveSmokeError.invalidDeepSeekBaseURL
        }

        let keyReference = "environment:NOONMARK_AI_API_KEY"
        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(
                providerID: AIProviderID("deepseek-live-smoke"),
                displayName: "DeepSeek live smoke",
                kind: .openAICompatible,
                baseURL: baseURL,
                model: model,
                apiKeyRef: keyReference,
                enabled: true,
                requestTimeoutSeconds: TimeInterval(
                    environment["NOONMARK_AI_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 30
                )
            ),
            apiKeyResolver: { reference in
                reference == keyReference ? apiKey : nil
            }
        )

        guard await provider.healthCheck().status == .healthy else {
            throw LiveSmokeError.providerUnavailable
        }

        let input = AutomaticTaskClassificationInput(
            title: "为晷迹实现新任务智能标签归类",
            description: "Swift macOS Todo 应用；验证空目录时自动建立分组与标签。",
            catalog: AutomaticTaskClassificationCatalog(
                revision: "deepseek-live-empty-catalog-v1",
                categories: [],
                labels: []
            )
        )
        let request = try AutomaticTaskClassificationPromptBuilder()
            .makeRequest(for: input)
        let response: AIProviderResponse
        do {
            response = try await provider.complete(request)
        } catch {
            throw LiveSmokeError.providerRequestFailed
        }
        let proposal: AutomaticTaskClassificationProposal
        do {
            proposal = try AutomaticTaskClassificationDecoder()
                .decode(response, against: input)
        } catch {
            throw LiveSmokeError.invalidClassificationProposal
        }
        guard case .create = proposal.category,
              proposal.labels.allSatisfy({ choice in
                  if case .create = choice { return true }
                  return false
              })
        else {
            throw LiveSmokeError.invalidClassificationProposal
        }
        return proposal.labels.count
    }

    private static func required(
        _ name: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            value.isEmpty == false
        else {
            throw LiveSmokeError.missingEnvironment(name)
        }
        return value
    }
}
