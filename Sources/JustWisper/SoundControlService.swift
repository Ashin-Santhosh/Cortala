import Foundation
import AppKit
import CoreAudio

/// Explicit opt-in output ducking. Never changes the default input or output device.
@MainActor
final class SoundControlService {
    private struct SavedVolume { var device: AudioDeviceID; var element: AudioObjectPropertyElement; var original: Float32; var ducked: Float32 }
    private var saved: [SavedVolume] = []
    private(set) var lastWarning: String?

    func start(feedback: Bool, duckOutput: Bool) {
        restore()
        lastWarning = nil
        if feedback { NSSound(named: "Tink")?.play() }
        guard duckOutput else { return }
        guard let device = defaultOutput() else { lastWarning = "The current output volume is unavailable for ducking."; return }
        let elements: [AudioObjectPropertyElement] = isSettable(device, element: kAudioObjectPropertyElementMain) ? [kAudioObjectPropertyElementMain] : [1, 2]
        for element in elements where isSettable(device, element: element) {
            guard let original = volume(device, element: element) else { continue }
            let ducked = original * 0.2
            if setVolume(ducked, device: device, element: element) {
                saved.append(SavedVolume(device: device, element: element, original: original, ducked: ducked))
            }
        }
        if saved.isEmpty { lastWarning = "This output device does not expose a controllable volume. Recording can continue." }
    }

    func stop(feedback: Bool) { restore(); if feedback { NSSound(named: "Pop")?.play() } }
    func cancel(feedback: Bool) { restore(); if feedback { NSSound(named: "Basso")?.play() } }

    /// If the user changed volume while recording, their new value wins.
    static func shouldRestore(current: Float32, ducked: Float32) -> Bool {
        current.isFinite && ducked.isFinite && abs(current - ducked) < 0.002
    }

    private func restore() {
        for value in saved {
            if let current = volume(value.device, element: value.element), Self.shouldRestore(current: current, ducked: value.ducked) {
                _ = setVolume(value.original, device: value.device, element: value.element)
            }
        }
        saved = []
    }

    private func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    private func defaultOutput() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr && device != 0 ? device : nil
    }
    private func isSettable(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var property = address(element)
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
    }
    private func volume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var property = address(element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
    private func setVolume(_ value: Float32, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var property = address(element)
        var value = min(1, max(0, value))
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}
