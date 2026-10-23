import Foundation
import AVFoundation

struct TranscriptionSegment: Codable, Equatable, Identifiable {
    var start: Double
    var end: Double
    var text: String
    var speaker: String?
    var id: String { "\(start)-\(end)-\(speaker ?? "")-\(text)" }
}

struct TranscriptionResult: Codable, Equatable {
    var text: String
    var segments: [TranscriptionSegment]

    static func decodeCloud(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Segment: Decodable { var start: Double; var end: Double; var text: String; var speaker: String? }
            var text: String
            var segments: [Segment]?
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        let segments = (value.segments ?? []).compactMap { segment -> TranscriptionSegment? in
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else { return nil }
            return TranscriptionSegment(start: segment.start, end: segment.end, text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines), speaker: segment.speaker)
        }
        return Self(text: value.text.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments)
    }

    static func decodeWhisper(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Segment: Decodable {
                struct Offset: Decodable { var from: Double; var to: Double }
                var offsets: Offset
                var text: String
            }
            var transcription: [Segment]
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        let segments = value.transcription.compactMap { segment -> TranscriptionSegment? in
            guard segment.offsets.from.isFinite, segment.offsets.to.isFinite, segment.offsets.from >= 0, segment.offsets.to >= segment.offsets.from else { return nil }
            return TranscriptionSegment(start: segment.offsets.from / 1000, end: segment.offsets.to / 1000,
                                        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines), speaker: nil)
        }
        return Self(text: segments.map(\.text).joined(separator: " "), segments: segments)
    }
}

struct SpeechProviderPreset: Identifiable {
    var id: String
    var name: String
    var endpoint: String
    var model: String
    static let all = [
        Self(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1/audio/transcriptions", model: "gpt-transcribe"),
        Self(id: "openai-whisper", name: "OpenAI Whisper · timestamps", endpoint: "https://api.openai.com/v1/audio/transcriptions", model: "whisper-1"),
        Self(id: "openai-diarize", name: "OpenAI speaker labels", endpoint: "https://api.openai.com/v1/audio/transcriptions", model: "gpt-4o-transcribe-diarize"),
        Self(id: "groq", name: "Groq", endpoint: "https://api.groq.com/openai/v1/audio/transcriptions", model: "whisper-large-v3-turbo"),
        Self(id: "local-server", name: "Local OpenAI-compatible server", endpoint: "http://localhost:8080/v1/audio/transcriptions", model: "whisper-1")
    ]
}

struct SpeechProviderCapabilities {
    var maximumUploadBytes: Int64
    var responseFormat: String
    var supportsPrompt: Bool
    var diarization: Bool
    static func resolve(endpoint: URL?, model: String) -> Self {
        let host = endpoint?.host?.lowercased() ?? ""
        let isOpenAI = host == "api.openai.com"
        let diarization = isOpenAI && model == "gpt-4o-transcribe-diarize"
        // Unknown compatible servers receive the smallest common request surface.
        let timestamps = (isOpenAI && model == "whisper-1") || host == "api.groq.com"
        return Self(maximumUploadBytes: 24_000_000, responseFormat: diarization ? "diarized_json" : (timestamps ? "verbose_json" : "json"),
                    supportsPrompt: !diarization, diarization: diarization)
    }
}

struct AudioChunkRange: Equatable {
    var start: Double
    var end: Double
}

enum AudioChunkPlan {
    static func ranges(duration: Double, maximumDuration: Double, overlap: Double) -> [AudioChunkRange] {
        guard duration.isFinite, duration > 0, maximumDuration.isFinite, maximumDuration > 0,
              overlap.isFinite, overlap >= 0, overlap < maximumDuration else { return [] }
        var ranges: [AudioChunkRange] = []
        var start = 0.0
        while start < duration {
            let end = min(duration, start + maximumDuration)
            ranges.append(AudioChunkRange(start: start, end: end))
            if end >= duration { break }
            start = end - overlap
        }
        return ranges
    }

    static func write(input: URL, output: URL, range: AudioChunkRange) throws {
        let source = try AVAudioFile(forReading: input)
        let rate = source.processingFormat.sampleRate
        source.framePosition = AVAudioFramePosition((range.start * rate).rounded())
        let last = min(source.length, AVAudioFramePosition((range.end * rate).rounded()))
        let destination = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192) else { throw ProviderError.message("Could not allocate audio chunk buffers.") }
        while source.framePosition < last {
            try Task.checkCancellation()
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, last - source.framePosition)))
            guard buffer.frameLength > 0 else { break }
            try destination.write(from: buffer)
        }
    }
}

enum TranscriptMerger {
    /// Only remove an exact suffix/prefix at a real chunk overlap. Never infer missing speakers or timestamps.
    static func merge(_ chunks: [(AudioChunkRange, TranscriptionResult)]) -> TranscriptionResult {
        var text = ""
        var segments: [TranscriptionSegment] = []
        var previousEnd = 0.0
        for (index, pair) in chunks.enumerated() {
            let (range, result) = pair
            let removed = range.start < previousEnd ? overlapWordCount(previous: text, next: result.text) : 0
            let words = result.text.split(whereSeparator: \.isWhitespace)
            let addition = words.dropFirst(removed).joined(separator: " ")
            if !addition.isEmpty { text += (text.isEmpty ? "" : " ") + addition }
            var wordsToRemove = removed
            for original in result.segments {
                var segment = original
                let tokens = segment.text.split(whereSeparator: \.isWhitespace)
                let cut = min(wordsToRemove, tokens.count)
                wordsToRemove -= cut
                segment.text = tokens.dropFirst(cut).joined(separator: " ")
                if segment.text.isEmpty { continue }
                segment.start += range.start
                segment.end += range.start
                // Independent cloud calls cannot establish speaker identity across chunks.
                if chunks.count > 1, let speaker = segment.speaker { segment.speaker = "Clip \(index + 1) · \(speaker)" }
                segments.append(segment)
            }
            previousEnd = max(previousEnd, range.end)
        }
        segments.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        return TranscriptionResult(text: text, segments: segments)
    }

    static func overlapWordCount(previous: String, next: String) -> Int {
        func tokens(_ value: String) -> [String] {
            value.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        }
        let before = tokens(previous), after = tokens(next)
        let maximum = min(32, before.count, after.count)
        guard maximum >= 2 else { return 0 }
        for length in stride(from: maximum, through: 2, by: -1) {
            if Array(before.suffix(length)) == Array(after.prefix(length)) { return length }
        }
        return 0
    }
}
