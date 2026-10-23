import Foundation
import AVFoundation

struct NoSpeechDetected: Error {}

enum NoSpeechPolicy {
    static func isAppleNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }
    static func isEmptyTranscript(_ text: String) -> Bool {
        var remaining = text
        for marker in ["[BLANK_AUDIO]", "[NO_SPEECH]", "[SILENCE]"] {
            remaining = remaining.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Only effectively zero PCM is skipped; quiet real speech must still reach ASR.
    static func isDigitalSilence(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return false }
                while file.framePosition < file.length {
                    guard !Task.isCancelled else { return false }
                    try file.read(into: buffer)
                    guard let channels = buffer.floatChannelData else { return false }
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            let value = channels[channel][frame]
                            if !value.isFinite || abs(value) > 0.00001 { return false }
                        }
                    }
                    if buffer.frameLength == 0 { break }
                }
                return true
            } catch { return false }
        }.value
    }
}
