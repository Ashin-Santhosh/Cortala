import Foundation

enum MeetingLanguageModelService {
    static func request(text: String, instruction: String, endpoint: URL, model: String, key: String) throws -> URLRequest {
        let native = isLocalOllama(endpoint)
        var request = try RewriteProtocol.request(text: String(text.suffix(480)), instruction: instruction, endpoint: endpoint, apiKey: key, model: model, context: nil)
        var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        if native {
            var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            parts.path = "/api/chat"; parts.query = nil; parts.fragment = nil
            request.url = parts.url
            body["think"] = false
            body["options"] = ["num_predict": 512, "temperature": 0]
        } else {
            switch RewriteProtocol.kind(endpoint: endpoint) {
            case .openAI, .anthropic: body["max_tokens"] = 512
            case .gemini: body["generationConfig"] = ["maxOutputTokens": 512]
            }
        }
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func isLocalOllama(_ endpoint: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(endpoint.host?.lowercased() ?? "") && endpoint.port == 11434 && endpoint.path == "/v1/chat/completions"
    }
    static func translate(text: String, instruction: String, endpoint: URL, model: String, key: String) async throws -> String {
        let data = try await ProviderHTTP.send(request(text: text, instruction: instruction, endpoint: endpoint, model: model, key: key))
        let result: String
        if isLocalOllama(endpoint) {
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["done"] as? Bool == true, body["done_reason"] as? String != "length",
                  let message = body["message"] as? [String: Any], let content = message["content"] as? String else {
                throw ProviderError.message("The translation model did not return a complete response. Try a faster model or shorter speech.")
            }
            result = content
        } else { result = try RewriteProtocol.decode(data, endpoint: endpoint) }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.message("The translation model returned no text. Choose another model or translation engine.") }
        return String(result.prefix(8000))
    }
}
