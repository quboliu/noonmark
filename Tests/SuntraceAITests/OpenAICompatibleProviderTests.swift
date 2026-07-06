@testable import SuntraceAI
import XCTest

final class OpenAICompatibleProviderTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testCompletePostsChatCompletionAndReturnsSummaryText() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        URLProtocolStub.handler = { request in
            capturedRequest = request
            capturedBody = request.httpBodyStream.flatMap(Self.data(from:))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"choices":[{"message":{"role":"assistant","content":"事实：今天有 2 个未完成。建议：减少承诺。"}}]}"#
            return (response, Data(body.utf8))
        }

        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(
                providerID: AIProviderID("openai-compatible"),
                displayName: "测试 Provider",
                kind: .openAICompatible,
                baseURL: URL(string: "https://provider.example/v1")!,
                model: "suntrace-model",
                apiKeyRef: "keychain:test",
                extraHeaders: ["X-Suntrace-Test": "1"]
            ),
            session: makeSession(),
            apiKeyResolver: { ref in
                XCTAssertEqual(ref, "keychain:test")
                return "secret-token"
            }
        )

        let response = try await provider.complete(
            AIRequest(
                systemPrompt: "系统边界",
                userPrompt: "授权范围",
                responseSchemaName: "suntrace.zhulong.suggestion_draft.v1"
            )
        )

        XCTAssertEqual(response.text, "事实：今天有 2 个未完成。建议：减少承诺。")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://provider.example/v1/chat/completions")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Suntrace-Test"), "1")

        let body = try XCTUnwrap(capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["model"] as? String, "suntrace-model")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.first?["content"], "系统边界")
        XCTAssertEqual(messages.last?["content"], "授权范围")
    }

    func testCompleteParsesStructuredSuggestionOperations() async throws {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let structured = #"{"summary":"建议先创建任务池任务。","confidence":0.66,"proposedOperations":[{"type":"createPoolTask","title":"整理远程结构化输出","descriptionText":"解析安全操作","note":"确认后落库"}]}"#
            let body = #"{"choices":[{"message":{"role":"assistant","content":"\#(structured.replacingOccurrences(of: "\"", with: "\\\""))"}}]}"#
            return (response, Data(body.utf8))
        }

        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(
                providerID: AIProviderID("openai-compatible"),
                displayName: "测试 Provider",
                kind: .openAICompatible,
                baseURL: URL(string: "https://provider.example/v1")!,
                model: "suntrace-model"
            ),
            session: makeSession()
        )

        let response = try await provider.complete(
            AIRequest(systemPrompt: "system", userPrompt: "user", responseSchemaName: "schema")
        )

        XCTAssertEqual(response.text, "建议先创建任务池任务。")
        XCTAssertEqual(response.confidence, 0.66)
        XCTAssertEqual(
            response.proposedOperations,
            [.createPoolTask(title: "整理远程结构化输出", descriptionText: "解析安全操作", note: "确认后落库")]
        )
    }

    func testCompleteFailsClosedWhenConfiguredKeyIsMissing() async throws {
        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(
                providerID: AIProviderID("openai-compatible"),
                displayName: "测试 Provider",
                kind: .openAICompatible,
                baseURL: URL(string: "https://provider.example/v1")!,
                model: "suntrace-model",
                apiKeyRef: "keychain:missing"
            ),
            session: makeSession(),
            apiKeyResolver: { _ in nil }
        )

        do {
            _ = try await provider.complete(
                AIRequest(systemPrompt: "system", userPrompt: "user", responseSchemaName: "schema")
            )
            XCTFail("missing API key should fail closed")
        } catch let error as AIProviderHTTPError {
            XCTAssertEqual(error, .missingAPIKey("keychain:missing"))
        }
    }

    func testHealthCheckUsesModelsEndpointAndReportsHealthy() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://provider.example/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(
                providerID: AIProviderID("openai-compatible"),
                displayName: "测试 Provider",
                kind: .openAICompatible,
                baseURL: URL(string: "https://provider.example/v1")!,
                model: "suntrace-model",
                apiKeyRef: "keychain:test"
            ),
            session: makeSession(),
            apiKeyResolver: { _ in "secret-token" }
        )

        let health = await provider.healthCheck()

        XCTAssertEqual(health.status, .healthy)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func data(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: AIProviderHTTPError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
