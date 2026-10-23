import AppKit
import SwiftUI

struct ModelReadinessNotifications {
    enum Phase { case warming, ready, failed, idle }
    private var previous: Phase = .idle
    mutating func transition(message: String, ready: Bool) -> Phase? {
        let next: Phase = message.hasPrefix("Warming") ? .warming : ready ? .ready :
            (message.contains("unavailable") || message.hasPrefix("Local live requires")) ? .failed : .idle
        guard next != previous else { return nil }
        previous = next
        return next
    }
}

@MainActor final class ModelReadinessOverlay {
    private final class State: ObservableObject {
        @Published var title = "Warming local Whisper"
        @Published var detail = "Preparing the model. First-time graphics setup can take longer."
        @Published var warming = true
    }
    private struct Content: View {
        @ObservedObject var state: State
        var body: some View {
            HStack(spacing: 14) {
                if state.warming { ProgressView().controlSize(.small) }
                else { Image(systemName: state.title == "Ready for dictation" ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(.mint) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title).font(.headline)
                    Text(state.detail).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).frame(width: 340, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private let state = State()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var notifications = ModelReadinessNotifications()
    func update(message: String, ready: Bool) {
        // Inference timing updates also notify observers. They are not new loads.
        guard let phase = notifications.transition(message: message, ready: ready) else { return }
        dismissal?.cancel()
        let warming = phase == .warming
        guard phase != .idle else { hide(); return }
        state.warming = warming
        state.title = warming ? "Warming local Whisper" : ready ? "Ready for dictation" : "Local model could not load"
        state.detail = warming ? "Preparing the model. First-time graphics setup can take longer." : ready ? "The model is loaded and stays ready while JustWisper is open." : "Check the model status in JustWisper Home."
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 376, height: 105), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false; window.backgroundColor = .clear
            window.hasShadow = true; window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: Content(state: state))
            panel = window
        }
        if let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 396, y: screen.visibleFrame.maxY - 125))
        }
        panel?.orderFrontRegardless()
        if !warming {
            dismissal = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(ready ? 3 : 8)) } catch { return }
                self?.panel?.orderOut(nil)
            }
        }
    }
    func hide() { dismissal?.cancel(); dismissal = nil; panel?.orderOut(nil) }
}
