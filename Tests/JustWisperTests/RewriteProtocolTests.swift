import Foundation
import Testing
@testable import JustWisper

struct RewriteProtocolTests {
    @Test func claudeNativeHeadersAndSeparateContextMessages() throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let request = try RewriteProtocol.request(text: "hello", instruction: "Fix punctuation", endpoint: endpoint,
            apiKey: "fixture", model: "claude-sonnet-4-5", context: #"{"selection":"context only"}"#)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["max_tokens"] as? Int == 8192)
        #expect(!(body["system"] as! String).contains("context only"))
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.last?["content"] == "hello")
        #expect(messages.first?["content"]?.contains("context only") == true)
        let output = try RewriteProtocol.decode(Data(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Hello."}],"stop_reason":"end_turn"}"#.utf8), endpoint: endpoint)
        #expect(output == "Hello.")
    }

    @Test func geminiNativeSchemaUsesSelectedModelAndHeaderKey() throws {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/old:generateContent?key=old-key")!
        let request = try RewriteProtocol.request(text: "hello", instruction: "Fix punctuation", endpoint: endpoint,
            apiKey: "fixture", model: "models/gemini-3.5-flash", context: nil)
        #expect(request.url?.path == "/v1beta/models/gemini-3.5-flash:generateContent")
        #expect(request.url?.query?.contains("key=") != true)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["systemInstruction"] != nil)
        #expect(body["messages"] == nil)
        let output = try RewriteProtocol.decode(Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"private"},{"text":"Hello."}]}}]}"#.utf8), endpoint: endpoint)
        #expect(output == "Hello.")
    }

    @Test func formattingTruncationAndEmptyRepliesAreRejected() {
        let fixtures = [
            ("https://api.anthropic.com/v1/messages", #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"Partial"}]}"#),
            ("https://generativelanguage.googleapis.com/v1beta/models/x:generateContent", #"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#),
            ("http://localhost:11434/v1/chat/completions", #"{"choices":[{"finish_reason":"length","message":{"content":"Partial"}}]}"#),
            ("https://api.anthropic.com/v1/messages", #"{"content":[]}"#)
        ]
        for (url, fixture) in fixtures {
            #expect(throws: (any Error).self) { try RewriteProtocol.decode(Data(fixture.utf8), endpoint: URL(string: url)!) }
        }
    }
}
