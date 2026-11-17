// OpenAI catalogue and GPT chat requests for AI Enhancement. Dictation uses its own endpoints.
import Foundation
import LLMkit

enum OpenAIEnhancementAPI {
    // A saved Default must survive legacy Mode migration, which backfills nil model values.
    static let automaticModelID = "default"

    static func listModels(apiKey: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let payload = try await response(for: request, session: session)
        let models = try JSONDecoder().decode(ModelList.self, from: payload)
        return Array(Set(models.data.map(\.id).filter(isCurrentChatModel)))
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    static func latestSol(in models: [String]) -> String? {
        models.filter { isCurrentChatModel($0) && $0.hasSuffix("-sol") }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    // The Models endpoint also lists speech, image, and dated snapshots. This
    // feature offers the stable GPT chat families our request format supports.
    static func isCurrentChatModel(_ id: String) -> Bool {
        id.range(of: #"^gpt-(?:[6-9]|[1-9]\d+)(?:\.\d+)?-(?:sol|astra|terra|luna)$"#,
                 options: .regularExpression) != nil
    }

    static func complete(
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String?,
        timeout: TimeInterval,
        session: URLSession = .shared
    ) async throws -> String {
        guard isCurrentChatModel(model) else {
            return try await OpenAILLMClient.chatCompletion(
                baseURL: URL(string: AIProvider.openAI.baseURL)!,
                apiKey: apiKey,
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: model.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3,
                reasoningEffort: ReasoningConfig.getReasoningParameter(for: .openAI, modelName: model),
                timeout: timeout
            )
        }

        var request = URLRequest(url: URL(string: AIProvider.openAI.baseURL)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var conversation = messages
        if let systemPrompt, !systemPrompt.isEmpty { conversation.insert(.system(systemPrompt), at: 0) }
        // LLMkit always sends temperature. GPT 6.2 rejects it and "none" effort.
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: conversation.map { .init(role: $0.role, content: $0.content) }
        ))
        let payload = try await response(for: request, session: session)
        let result = try JSONDecoder().decode(ChatResponse.self, from: payload)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw LLMKitError.noResultReturned
        }
        return content
    }

    private static func response(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LLMKitError.httpError(statusCode: response.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct ChatRequest: Encodable {
        struct Message: Codable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let reasoning_effort = "low"
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
}
