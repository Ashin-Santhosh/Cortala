import Foundation

enum FastDictationRecovery {
    /// An on-device session must never silently turn into a cloud audio upload.
    static func canUseSelectedLocalModel(settings: AppSettings, mode: DictationMode) -> Bool {
        settings.speechProvider == "local" && mode.speechConnectionID == nil
    }
}
