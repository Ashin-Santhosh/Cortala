import Foundation
import CoreAudio

struct AudioInputDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var deviceID: AudioDeviceID

    static func available() -> [AudioInputDevice] {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var identifiers = Array(repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &identifiers) == noErr else { return [] }
        return identifiers.compactMap { device in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &input, 0, nil, &inputSize) == noErr, inputSize > 0,
                  let uid = string(device, selector: kAudioDevicePropertyDeviceUID), let name = string(device, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: uid, name: name, deviceID: device)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Optional preview of actual rolling microphone samples. Final transcription still uses the full recording.
@MainActor
final class ProvisionalTranscriptionService {
    private var task: Task<Void, Never>?
    func start(recorder: AudioRecorderService, request: TranscriptionRequest,
               onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        start(snapshot: { try recorder.snapshot() }, request: request, onUpdate: onUpdate, onError: onError)
    }
    func start(snapshot: @escaping @MainActor () async throws -> URL, request: TranscriptionRequest,
               onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        task = Task {
            var emptySnapshots = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    let audio = try await snapshot()
                    emptySnapshots = 0
                    defer { try? FileManager.default.removeItem(at: audio) }
                    try Task.checkCancellation()
                    var preview = request
                    preview.audioURL = audio
                    let result = try await TranscriptionService.transcribe(preview)
                    try Task.checkCancellation()
                    if !result.isEmpty { onUpdate(result) }
                } catch is CancellationError { break }
                catch AudioSnapshotError.notReady {
                    emptySnapshots += 1
                    if emptySnapshots >= 3 { onError("No audio samples are available for live previews yet. The full recording continues."); break }
                }
                catch { if !Task.isCancelled { onError(error.localizedDescription) }; break }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}
