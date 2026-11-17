import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct OpenAIEnhancementAPITests {
    @Test func discoveredModelsExcludeOtherRolesAndDefaultToLatestSol() async throws {
        let session = Self.mockSession()
        defer { session.invalidateAndCancel() }
        let models = try await OpenAIEnhancementAPI.listModels(apiKey: "fixture", session: session)
        #expect(models == ["gpt-7-astra", "gpt-6.10-sol", "gpt-6.2-sol"])
        #expect(OpenAIEnhancementAPI.latestSol(in: models) == "gpt-6.10-sol")
        #expect(OpenAIEnhancementAPI.latestSol(in: ["gpt-7-astra"]) == nil)
    }

    @Test func currentSolUsesCompatibleChatRequest() async throws {
        let session = Self.mockSession()
        defer { session.invalidateAndCancel() }
        let result = try await OpenAIEnhancementAPI.complete(
            apiKey: "fixture", model: "gpt-6.2-sol", messages: [.user("a test")],
            systemPrompt: "Rewrite this", timeout: 3, session: session
        )
        #expect(result == "Edited text")
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIFixture.self]
        return URLSession(configuration: config)
    }
}

private final class OpenAIFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        #expect(url.host == "api.openai.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let json: String
        switch (request.httpMethod, url.path) {
        case ("GET", "/v1/models"):
            json = #"{"data":[{"id":"gpt-6.2-sol"},{"id":"gpt-live-transcribe"},{"id":"gpt-7-astra"},{"id":"gpt-6.10-sol"},{"id":"gpt-6.2-sol-2026-11-17"},{"id":"gpt-image-2"}]}"#
        case ("POST", "/v1/chat/completions"):
            let payload = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBody)
            let body = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            #expect(body?["model"] as? String == "gpt-6.2-sol")
            #expect(body?["reasoning_effort"] as? String == "low")
            #expect(body?["temperature"] == nil)
            let messages = body?["messages"] as? [[String: String]]
            #expect(messages?.map { $0["role"] } == ["system", "user"])
            json = #"{"choices":[{"message":{"content":"Edited text"}}]}"#
        default:
            Issue.record("Unexpected OpenAI fixture request")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let length = stream.read(&buffer, maxLength: buffer.count)
            if length < 0 { return nil }
            if length == 0 { return body }
            body.append(contentsOf: buffer.prefix(length))
        }
    }
}
