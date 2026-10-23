import AppKit
import Carbon
import SwiftUI

/// A key-capable nonactivating panel leaves the destination application active.
/// No destination, selection, or context is cached while choosing a mode.
@MainActor
final class ModeSwitcherPanel {
    private let state = ModeSwitcherState()
    private var panel: ModeSelectionPanel?
    private var onChoose: ((UUID) -> Void)?
    private var onRecord: ((UUID) -> Void)?

    func show(modes: [DictationMode], selectedID: UUID?, onChoose: @escaping (UUID) -> Void, onRecord: @escaping (UUID) -> Void) {
        guard !modes.isEmpty else { return }
        self.onChoose = onChoose
        self.onRecord = onRecord
        state.modes = modes
        state.selection = ModeSwitcherSelection(count: modes.count, selectedIndex: modes.firstIndex { $0.id == selectedID } ?? 0)
        if panel == nil {
            let panel = ModeSelectionPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
            panel.contentView = NSHostingView(rootView: ModeSwitcherView(state: state,
                choose: { [weak self] in self?.finish(record: false) },
                record: { [weak self] in self?.finish(record: true) },
                dismiss: { [weak self] in self?.hide() }))
            self.panel = panel
        }
        let height = min(480, 130 + CGFloat(modes.count) * 44)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel?.setFrame(NSRect(x: screen.visibleFrame.midX - 190, y: screen.visibleFrame.midY - height / 2, width: 380, height: height), display: true)
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        onChoose = nil
        onRecord = nil
    }

    private func finish(record: Bool) {
        guard let index = state.selection.selectedIndex, state.modes.indices.contains(index) else { return }
        let id = state.modes[index].id
        let callback = record ? onRecord : onChoose
        hide()
        // Give AppKit a turn to release the key panel before a recording action
        // captures the current actual destination and its current focused field.
        DispatchQueue.main.async { callback?(id) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape: hide(); return true
        case kVK_UpArrow: state.selection.move(-1); return true
        case kVK_DownArrow: state.selection.move(1); return true
        case kVK_Tab: state.selection.move(event.modifierFlags.contains(.shift) ? -1 : 1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter: finish(record: event.modifierFlags.contains(.command)); return true
        default: return false
        }
    }
}

@MainActor
private final class ModeSelectionPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
private final class ModeSwitcherState: ObservableObject {
    @Published var modes: [DictationMode] = []
    @Published var selection = ModeSwitcherSelection(count: 0)
}

private struct ModeSwitcherView: View {
    @ObservedObject var state: ModeSwitcherState
    var choose: () -> Void
    var record: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Choose a mode").font(.headline); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close mode switcher") }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(state.modes.enumerated()), id: \.element.id) { index, mode in
                            Button {
                                state.selection = ModeSwitcherSelection(count: state.modes.count, selectedIndex: index)
                            } label: {
                                HStack { Image(systemName: mode.icon).frame(width: 22); Text(mode.name).lineLimit(1); Spacer(); if index == state.selection.index { Image(systemName: "checkmark") } }
                                    .padding(.horizontal, 12).frame(height: 40)
                                    .background(index == state.selection.index ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                        }
                    }
                }.onChange(of: state.selection.index) { _, index in proxy.scrollTo(index, anchor: .center) }
            }
            HStack {
                Text("↑↓ navigate · Esc close").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use mode ↩", action: choose)
                Button("Record ⌘↩", action: record).buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
    }
}
