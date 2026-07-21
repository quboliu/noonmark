import Foundation
import NoonmarkAI

private enum LiveSmokeError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case invalidDeepSeekBaseURL
    case providerUnavailable
    case providerRequestFailed
    case invalidClassificationProposal
    case providerStreamFailed
    case invalidStreamedConversation

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
        case .providerStreamFailed:
            "DeepSeek streaming request did not succeed"
        case .invalidStreamedConversation:
            "DeepSeek did not return multiple usable streaming fragments"
        }
    }
}

@main
private struct NoonmarkAIProviderLiveSmoke {
    static func main() async {
        do {
            let result = try await run()
            print(
                "DeepSeek live automatic-classification and streaming contracts passed "
                    + "(one category, \(result.labelCount) labels, "
                    + "\(result.streamFragmentCount) streamed fragments)."
            )
        } catch let error as LiveSmokeError {
            fputs("DeepSeek live automatic-classification contract failed: \(error)\n", stderr)
            exit(1)
        } catch {
            fputs("DeepSeek live automatic-classification contract failed: internal error\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws -> (
        labelCount: Int,
        streamFragmentCount: Int
    ) {
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

        let streamRequest = AIRequest(
            systemPrompt: "你是晷迹中的烛龙。回答清晰、简短、直接。",
            userPrompt: "请用三句中文说明如何开始规划一项任务；每句不超过二十字。",
            responseSchemaName: "noonmark.zhulong.live-stream.v1"
        )
        let stream: AsyncThrowingStream<String, Error>
        do {
            stream = try await provider.stream(streamRequest)
        } catch {
            throw LiveSmokeError.providerStreamFailed
        }
        var streamFragmentCount = 0
        var streamedCharacterCount = 0
        do {
            for try await fragment in stream {
                guard fragment.isEmpty == false else { continue }
                streamFragmentCount += 1
                streamedCharacterCount += fragment.count
            }
        } catch {
            throw LiveSmokeError.providerStreamFailed
        }
        guard streamFragmentCount >= 2, streamedCharacterCount >= 12 else {
            throw LiveSmokeError.invalidStreamedConversation
        }
        return (proposal.labels.count, streamFragmentCount)
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
