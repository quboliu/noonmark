import Foundation

public typealias AIAPIKeyResolver = @Sendable (String) async throws -> String?

public enum AIProviderHTTPError: Error, Equatable, Sendable {
    case missingBaseURL
    case missingModel
    case missingAPIKey(String)
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyResponse
}

public struct OpenAICompatibleProvider: AIProvider {
    public let config: AIProviderConfig

    private let session: URLSession
    private let apiKeyResolver: AIAPIKeyResolver

    public init(
        config: AIProviderConfig,
        session: URLSession = .shared,
        apiKeyResolver: @escaping AIAPIKeyResolver = { _ in nil }
    ) {
        self.config = config
        self.session = session
        self.apiKeyResolver = apiKeyResolver
    }

    public func complete(_ request: AIRequest) async throws -> AIProviderResponse {
        let model = try modelName()
        let url = try endpoint("chat/completions")
        var urlRequest = try await authorizedRequest(url: url, method: "POST")
        urlRequest.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(role: "system", content: request.systemPrompt),
                    ChatMessage(role: "user", content: request.userPrompt)
                ],
                responseFormat: request.responseFormat == .jsonObject
                    ? ChatCompletionResponseFormat(type: "json_object")
                    : nil
            )
        )

        let data = try await send(urlRequest)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              content.isEmpty == false
        else {
            throw AIProviderHTTPError.emptyResponse
        }

        return AIProviderResponse(
            text: content,
            rawContent: content
        )
    }

    public func healthCheck() async -> AIProviderHealth {
        guard config.enabled else {
            return AIProviderHealth(status: .unconfigured, message: "Provider 已关闭")
        }

        do {
            _ = try modelName()
            let url = try endpoint("models")
            let request = try await authorizedRequest(url: url, method: "GET")
            _ = try await send(request)
            return AIProviderHealth(status: .healthy, message: "Provider 可用")
        } catch {
            return AIProviderHealth(status: .unavailable, message: String(describing: error))
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let baseURL = config.baseURL else {
            throw AIProviderHTTPError.missingBaseURL
        }
        return baseURL.appendingPathComponent(path)
    }

    private func modelName() throws -> String {
        let model = config.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard model.isEmpty == false else {
            throw AIProviderHTTPError.missingModel
        }
        return model
    }

    private func authorizedRequest(url: URL, method: String) async throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: config.requestTimeoutSeconds)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for header in config.extraHeaders.sorted(by: { $0.key < $1.key }) {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        if let apiKeyRef = config.apiKeyRef {
            guard let apiKey = try await apiKeyResolver(apiKeyRef), apiKey.isEmpty == false else {
                throw AIProviderHTTPError.missingAPIKey(apiKeyRef)
            }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderHTTPError.invalidResponse
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            let providerMessage = try? JSONDecoder().decode(ProviderErrorResponse.self, from: data).error.message
            throw AIProviderHTTPError.httpStatus(httpResponse.statusCode, providerMessage)
        }
        return data
    }
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature = 0.2
    var responseFormat: ChatCompletionResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct ChatCompletionResponseFormat: Encodable {
    var type: String
}

private struct ChatMessage: Codable, Equatable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: ChatMessage
    }
}

private struct ProviderErrorResponse: Decodable {
    var error: ProviderError

    struct ProviderError: Decodable {
        var message: String
    }
}
