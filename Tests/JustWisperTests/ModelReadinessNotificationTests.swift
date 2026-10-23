import Testing
@testable import JustWisper

struct ModelReadinessNotificationTests {
    @Test func inferenceAndRecordingUpdatesCannotReplayReady() {
        var notices = ModelReadinessNotifications()
        #expect(notices.transition(message: "Warming local Whisper…", ready: false) == .warming)
        #expect(notices.transition(message: "Warming local Whisper…", ready: false) == nil)
        #expect(notices.transition(message: "Local Whisper ready · model resident in memory", ready: true) == .ready)
        for _ in 0..<20 {
            #expect(notices.transition(message: "Local Whisper ready · model resident in memory", ready: true) == nil)
        }
    }
    @Test func genuineReloadCanNotifyAgainAndFailureDoesNotRepeat() {
        var notices = ModelReadinessNotifications()
        #expect(notices.transition(message: "Ready", ready: true) == .ready)
        #expect(notices.transition(message: "Local live model released", ready: false) == .idle)
        #expect(notices.transition(message: "Warming local Whisper…", ready: false) == .warming)
        #expect(notices.transition(message: "Local live model unavailable: fixture", ready: false) == .failed)
        #expect(notices.transition(message: "Local live model unavailable: fixture", ready: false) == nil)
        #expect(notices.transition(message: "Warming local Whisper…", ready: false) == .warming)
        #expect(notices.transition(message: "Ready", ready: true) == .ready)
    }
}
