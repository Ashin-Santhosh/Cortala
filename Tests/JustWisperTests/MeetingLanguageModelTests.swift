import Foundation
import Testing
@testable import JustWisper

struct MeetingLanguageModelTests {
    @Test func localTranslationDisablesReasoningAndBoundsOutputWithoutChangingOrigin() throws {
        let endpoint = URL(string: "http://localhost:11434/v1/chat/completions")!
        let request = try MeetingLanguageModelService.request(text: "Hello", instruction: "Translate into German", endpoint: endpoint, model: "fixture", key: "")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(body["think"] as? Bool == false)
        #expect(body["stream"] as? Bool == false)
        #expect((body["options"] as? [String: Int])?["num_predict"] == 512)
    }
    @Test func remoteOrOtherLocalProvidersKeepTheirConfiguredRoute() throws {
        for value in ["https://example.com/v1/chat/completions", "http://localhost:1234/v1/chat/completions"] {
            let endpoint = URL(string: value)!
            let request = try MeetingLanguageModelService.request(text: "Hello", instruction: "Translate", endpoint: endpoint, model: "fixture", key: "")
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(request.url == endpoint)
            #expect(body["think"] == nil)
            #expect(body["max_tokens"] as? Int == 512)
        }
    }
}
