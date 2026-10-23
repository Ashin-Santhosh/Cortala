import Foundation
import Testing
import AVFoundation
@testable import JustWisper

struct StreamingSpeechTests {
    @Test func partialUpdatesReplaceAndFinalCannotDuplicateOrRegress() {
        var buffer = StreamingTranscriptAccumulator()
        let first = UUID(), second = UUID()
        buffer.update(id: first, source: .microphone, text: "Hello", isFinal: false)
        buffer.update(id: first, source: .microphone, text: "Hello world", isFinal: false)
        #expect(buffer.rendered(labelSources: false) == "Hello world")
        buffer.update(id: first, source: .microphone, text: "Hello world.", isFinal: true)
        buffer.update(id: first, source: .microphone, text: "Hello", isFinal: false)
        buffer.update(id: first, source: .microphone, text: "Hello world.", isFinal: true)
        buffer.update(id: second, source: .microphone, text: "Next utterance", isFinal: false)
        #expect(buffer.rendered(labelSources: false) == "Hello world.\nNext utterance")
        #expect(buffer.utterances.count == 2)
    }
    @Test func captureInputsAreLabeledWithoutInventingSpeakerIdentity() {
        var buffer = StreamingTranscriptAccumulator()
        buffer.update(id: UUID(), source: .microphone, text: "Local voice", isFinal: true)
        buffer.update(id: UUID(), source: .system, text: "Remote voice", isFinal: false)
        #expect(buffer.rendered(labelSources: true) == "Microphone: Local voice\nSystem audio: Remote voice")
        #expect(!buffer.rendered(labelSources: true).contains("Speaker"))
    }
    @Test func recentIncrementalCaptionStateIsBounded() {
        var buffer = StreamingTranscriptAccumulator()
        for index in 0..<150 { buffer.update(id: UUID(), source: .system, text: "Turn \(index)", isFinal: true) }
        #expect(buffer.utterances.count == 100)
        #expect(buffer.utterances.first?.text == "Turn 50")
        #expect(buffer.discardedUtterances)
    }
    @Test func finalizationRequiresActualFinalFlagsAndCompletionOfEveryRequest() {
        var buffer = StreamingTranscriptAccumulator(retainFullTranscript: true)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 0, failed: false) == .empty)
        let id = UUID()
        buffer.update(id: id, source: .microphone, text: "Last words", isFinal: false)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 1, failed: false) == .waiting)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 0, failed: false) == .incomplete)
        buffer.update(id: id, source: .microphone, text: "Last words.", isFinal: true)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 1, failed: false) == .waiting)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 0, failed: false) == .ready)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 0, failed: true) == .failed)
        buffer.update(id: UUID(), source: .microphone, text: "An unfinished tail", isFinal: false)
        #expect(StreamingFinalizationState.evaluate(buffer, pendingRequests: 0, failed: false) == .incomplete)
    }
    @Test func fastDictationRetainsTheWholeTranscriptWhileCaptionTruncationCannotFinalize() {
        var full = StreamingTranscriptAccumulator(retainFullTranscript: true)
        var captions = StreamingTranscriptAccumulator()
        for index in 0..<150 {
            let id = UUID(), text = "Utterance \(index)"
            full.update(id: id, source: .microphone, text: text, isFinal: true)
            captions.update(id: id, source: .microphone, text: text, isFinal: true)
        }
        #expect(full.utterances.count == 150)
        #expect(full.rendered(labelSources: false).hasPrefix("Utterance 0\n"))
        #expect(StreamingFinalizationState.evaluate(full, pendingRequests: 0, failed: false) == .ready)
        #expect(StreamingFinalizationState.evaluate(captions, pendingRequests: 0, failed: false) == .incomplete)
    }
    @Test func callbackAudioIsCopiedBeforeQueuedRecognition() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let original = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        original.frameLength = 3
        original.floatChannelData![0][0] = 0.25
        original.floatChannelData![1][2] = -0.5
        let copy = try #require(SpeechAudioCopy.copy(original))
        original.floatChannelData![0][0] = 1
        original.floatChannelData![1][2] = 1
        #expect(copy.frameLength == 3)
        #expect(copy.floatChannelData![0][0] == 0.25)
        #expect(copy.floatChannelData![1][2] == -0.5)
    }
    @Test func finishingDrainsAcceptedAudioAndRejectsLateOrPreviousRunCallbacks() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        audio.frameLength = 1
        let ingress = SpeechAudioIngress(), first = UUID(), second = UUID()
        let item = SpeechAudioIngress.Item(buffer: SpeechBufferTransfer(audio), source: .microphone)
        ingress.open(first)
        #expect(ingress.enqueue(item) == first)
        #expect(ingress.drain(first, close: true).count == 1)
        #expect(ingress.enqueue(item) == nil)
        #expect(ingress.drain(first).isEmpty)
        ingress.open(second)
        #expect(ingress.enqueue(item, expectedRun: first) == nil)
        #expect(ingress.enqueue(item) == second)
        #expect(ingress.drain(first, close: true).isEmpty)
        #expect(ingress.drain(second, close: true).count == 1)
    }
    @Test func meetingPromptIncludesOnlySuppliedSpeakerTimes() throws {
        let segments = [TranscriptionSegment(start: 1.5, end: 3.5, text: "We agreed", speaker: "Speaker 1")]
        let payload = try MeetingTranscriptEvidence.payload(transcript: "We agreed", segments: segments, question: "Who spoke?")
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let encoded = try #require(object["segments"] as? [[String: Any]])
        #expect(object["transcript"] as? String == "We agreed")
        #expect(object["question"] as? String == "Who spoke?")
        #expect(encoded.first?["start"] as? Double == 1.5)
        #expect(encoded.first?["speaker"] as? String == "Speaker 1")
        let plain = try MeetingTranscriptEvidence.payload(transcript: "No timing", segments: [])
        #expect(plain.contains("\"segments\":[]"))
    }
}
