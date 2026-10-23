import Foundation
import AVFoundation
import Testing
@testable import JustWisper

struct DiarizationTests {
    @Test func alignmentRetainsASRTimestampsAndLeavesAmbiguousTurnsExplicit() {
        let text = TranscriptionResult(text: "A B C", segments: [
            TranscriptionSegment(start: 0, end: 2, text: "A"),
            TranscriptionSegment(start: 2, end: 4, text: "B"),
            TranscriptionSegment(start: 4, end: 6, text: "C")])
        let result = SpeakerTranscriptAlignment.annotate(text, ranges: [
            SpeakerTimeRange(start: 0, end: 2, speaker: "S1"),
            SpeakerTimeRange(start: 2, end: 3, speaker: "S1"),
            SpeakerTimeRange(start: 3, end: 4, speaker: "S2")])
        #expect(result.segments.map(\.speaker) == ["Speaker S1", "Multiple speakers", nil])
        #expect(result.segments.map(\.start) == [0, 2, 4])
        #expect(result.text == text.text)
    }

    @Test func pinnedSpeakerAssetsRejectMissingAndCorruptFiles() throws {
        #expect(DiarizationModelService.assets.count == 25)
        #expect(DiarizationModelService.assets.allSatisfy { !$0.path.contains("..") && $0.sha256.count == 64 && $0.size > 0 })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try DiarizationModelService.verifyFile(url, asset: DiarizationModelService.assets[0]) }
    }

    /// Explicit opt-in. Uses two built-in synthesized voices without playback, permissions, or personal audio.
    /// This verifies model execution and turn separation, not real human speaker accuracy.
    @Test func actualOfflineModelsSeparateTwoSyntheticVoices() async throws {
        guard ProcessInfo.processInfo.environment["JUSTWISPER_DIARIZATION_SMOKE"] == "1" else { return }
        guard #available(macOS 15, *) else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = root.appendingPathComponent("Models/Diarization")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper-two-voices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let lines = [
            "We need to decide the project schedule today. I propose we finish the first prototype next week and review the results together before we start the next phase.",
            "That sounds reasonable to me. I can prepare the design documents and share them tomorrow morning. Then our team can review the details and suggest any changes before the next meeting."
        ]
        var samples: [[Float]] = []
        for (index, voice) in ["Samantha", "Daniel"].enumerated() {
            let aiff = temporary.appendingPathComponent("\(index).aiff")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", voice, "-o", aiff.path, lines[index]]
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let wav = temporary.appendingPathComponent("\(index).wav")
            try AudioConversion.toWhisperWAV(input: aiff, output: wav)
            let file = try AVAudioFile(forReading: wav)
            guard file.length > 0 else { throw ProviderError.message("The fixture voice produced no samples. Run the opt-in smoke with normal macOS speech service access.") }
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            samples.append(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let fixture = temporary.appendingPathComponent("two-voice.wav")
        var expected: [SpeakerTimeRange] = []
        do {
            let file = try AVAudioFile(forWriting: fixture, settings: format.settings)
            var time = 0.0
            for index in [0, 1, 0, 1] {
                let values = samples[index]
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count + 8_000))!
                buffer.frameLength = buffer.frameCapacity
                buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
                values.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: values.count) }
                try file.write(from: buffer)
                let end = time + Double(values.count) / 16_000
                expected.append(SpeakerTimeRange(start: time, end: end, speaker: String(index)))
                time = end + 0.5
            }
        }
        let began = Date()
        let result = try await OfflineDiarizationService().ranges(audioURL: fixture, modelDirectory: models)
        let speakers = Set(result.map(\.speaker))
        print("DIARIZATION_SMOKE speakers=\(speakers.sorted()) seconds=\(Date().timeIntervalSince(began)) ranges=\(result)")
        #expect(speakers.count == 2)
        var assignments: [String] = []
        for turn in expected {
            var overlap: [String: Double] = [:]
            for range in result { overlap[range.speaker, default: 0] += max(0, min(turn.end, range.end) - max(turn.start, range.start)) }
            let best = overlap.max { $0.value < $1.value }
            let coverage = (best?.value ?? 0) / (turn.end - turn.start)
            print("DIARIZATION_TURN expected=\(turn.speaker) predicted=\(best?.key ?? "none") coverage=\(coverage)")
            #expect(coverage > 0.6)
            assignments.append(best?.key ?? "")
        }
        #expect(assignments[0] == assignments[2])
        #expect(assignments[1] == assignments[3])
        #expect(assignments[0] != assignments[1])

        // Exercise the real ASR-to-speaker path too: coarse ASR sentences used
        // to span both voices, so the UI showed only "Multiple speakers" even
        // though the model itself separated these four turns correctly.
        let transcript = try await TranscriptionService.transcribeDetailed(TranscriptionRequest(audioURL: fixture, endpoint: nil,
            apiKey: "", model: "", language: "en", vocabulary: "", localExecutable: "/opt/homebrew/bin/whisper-cli",
            localModel: root.appendingPathComponent("Models/ggml-medium.bin").path, provider: "local"))
        let annotated = SpeakerTranscriptAlignment.annotate(transcript, ranges: result)
        #expect(annotated.text == transcript.text)
        #expect(annotated.segments.map(\.start) == transcript.segments.map(\.start))
        #expect(annotated.segments.map(\.end) == transcript.segments.map(\.end))
        let named = Set(annotated.segments.compactMap(\.speaker).filter { $0.hasPrefix("Speaker ") })
        #expect(named == Set(assignments.map { "Speaker \($0)" }))
        for (index, turn) in expected.enumerated() {
            var recognized = 0.0, correctlyLabeled = 0.0
            for segment in annotated.segments {
                let overlap = max(0, min(turn.end, segment.end) - max(turn.start, segment.start))
                recognized += overlap
                if segment.speaker == "Speaker \(assignments[index])" { correctlyLabeled += overlap }
            }
            let coverage = correctlyLabeled / max(recognized, 0.001)
            print("DIARIZATION_ASR_TURN expected=\(assignments[index]) labeledCoverage=\(coverage)")
            #expect(recognized > 0)
            #expect(coverage > 0.6)
        }
        if let destination = ProcessInfo.processInfo.environment["JUSTWISPER_ACCEPTANCE_AUDIO_PATH"] {
            let url = URL(fileURLWithPath: destination)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: fixture, to: url)
            let truth = expected.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker] as [String: Any] }
            try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.deletingPathExtension().appendingPathExtension("groundtruth.json"))
        }
    }
}
