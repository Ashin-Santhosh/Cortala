import Foundation
import AVFoundation
import Testing
@testable import JustWisper

struct TranscriptionPipelineTests {
    @Test func chunkRangesCoverLongAudioWithBoundedUploads() {
        let ranges = AudioChunkPlan.ranges(duration: 1_805, maximumDuration: 600, overlap: 2)
        #expect(ranges.first?.start == 0)
        #expect(ranges.last?.end == 1_805)
        #expect(ranges.count == 4)
        for index in ranges.indices {
            #expect(ranges[index].end - ranges[index].start <= 600)
            if index > 0 { #expect(ranges[index].start == ranges[index - 1].end - 2) }
        }
        #expect(AudioChunkPlan.ranges(duration: .infinity, maximumDuration: 600, overlap: 2).isEmpty)
        #expect(AudioChunkPlan.ranges(duration: 10, maximumDuration: 2, overlap: 2).isEmpty)
    }

    @Test func mergerDeduplicatesOverlapAndPreservesLanguageAndAbsoluteTimestamps() {
        let first = TranscriptionResult(text: "Guten Morgen wir beginnen heute", segments: [
            TranscriptionSegment(start: 0, end: 8, text: "Guten Morgen wir beginnen heute", speaker: nil)
        ])
        let second = TranscriptionResult(text: "beginnen heute mit dem Projekt", segments: [
            TranscriptionSegment(start: 0, end: 2, text: "beginnen heute", speaker: nil),
            TranscriptionSegment(start: 2, end: 5, text: "mit dem Projekt", speaker: nil)
        ])
        let merged = TranscriptMerger.merge([(.init(start: 0, end: 10), first), (.init(start: 8, end: 16), second)])
        #expect(merged.text == "Guten Morgen wir beginnen heute mit dem Projekt")
        #expect(merged.segments.count == 2)
        #expect(merged.segments[1].start == 10)
        #expect(merged.segments[1].end == 13)
        #expect(merged.segments.allSatisfy { $0.speaker == nil })
    }

    @Test func repeatedPhraseOutsideOverlapIsPreservedAndSpeakerIDsAreScoped() {
        let first = TranscriptionResult(text: "Please start again", segments: [.init(start: 0, end: 2, text: "Please start again", speaker: "A")])
        let second = TranscriptionResult(text: "Please start again", segments: [.init(start: 0, end: 2, text: "Please start again", speaker: "A")])
        let merged = TranscriptMerger.merge([(.init(start: 0, end: 4), first), (.init(start: 4, end: 8), second)])
        #expect(merged.text == "Please start again Please start again")
        #expect(merged.segments[0].speaker != merged.segments[1].speaker)
    }

    @Test func genuineWhisperAndCloudMetadataAreDecoded() throws {
        let whisper = Data(#"{"transcription":[{"offsets":{"from":1230,"to":4560},"text":" Hallo Welt"}]}"#.utf8)
        let local = try TranscriptionResult.decodeWhisper(whisper)
        #expect(local.text == "Hallo Welt")
        #expect(local.segments[0].start == 1.23)
        #expect(local.segments[0].end == 4.56)
        let cloud = try TranscriptionResult.decodeCloud(Data(#"{"text":"Hello","segments":[{"start":0,"end":1.2,"text":"Hello","speaker":"A"}]}"#.utf8))
        #expect(cloud.segments.first?.speaker == "A")
        let noTimestamps = try TranscriptionResult.decodeCloud(Data(#"{"text":"Hello"}"#.utf8))
        #expect(noTimestamps.segments.isEmpty)
    }

    @Test func diarizationMultipartUsesSupportedFieldsAndPreservesExactAudioBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let audio = Data([0, 1, 2, 250, 255])
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = TranscriptionRequest(audioURL: url, endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions"),
            apiKey: "test-key", model: "gpt-4o-transcribe-diarize", language: "de", vocabulary: "Do not send this prompt",
            localExecutable: "", localModel: "", provider: "cloud")
        let capabilities = SpeechProviderCapabilities.resolve(endpoint: request.endpoint, model: request.model)
        let http = try TranscriptionService.cloudRequest(request, capabilities: capabilities)
        let body = http.httpBody!
        let fields = String(decoding: body, as: UTF8.self)
        #expect(http.httpMethod == "POST")
        #expect(http.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(fields.contains("diarized_json"))
        #expect(fields.contains("chunking_strategy"))
        #expect(fields.contains("\r\n\r\nde\r\n"))
        #expect(!fields.contains("Do not send this prompt"))
        #expect(!fields.contains("timestamp_granularities"))
        #expect(body.range(of: audio) != nil)
        #expect(fields.contains("filename=\"recording.wav\"\r\nContent-Type: audio/wav"))
    }

    @Test func chunkAudioContainsOnlyRequestedFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("chunk.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = index < 16_000 ? 0.1 : 0.6 }
        do {
            let writer = try AVAudioFile(forWriting: input, settings: format.settings)
            try writer.write(from: buffer)
        }
        try AudioChunkPlan.write(input: input, output: output, range: .init(start: 1, end: 2))
        let reader = try AVAudioFile(forReading: output)
        #expect(reader.length == 16_000)
        let actual = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 16_000)!
        try reader.read(into: actual)
        #expect(abs(actual.floatChannelData![0][0] - 0.6) < 0.001)
        #expect(abs(actual.floatChannelData![0][15_999] - 0.6) < 0.001)
    }

    @Test func modelVerificationRejectsCorruptionAndCatalogIsAllowlisted() throws {
        #expect(LocalModelDescriptor.catalog.count == 4)
        #expect(LocalModelDescriptor.catalog.allSatisfy { $0.sha256.count == 64 && $0.downloadURL.host == "huggingface.co" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = LocalModelDescriptor(id: "test", name: "Test", filename: "test", byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try ModelDownloadService.verifyFile(url, model: model)
        try Data("abd".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ModelDownloadService.verifyFile(url, model: model) }
    }
}
