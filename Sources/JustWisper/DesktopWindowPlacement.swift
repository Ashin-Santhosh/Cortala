import AppKit
import ApplicationServices

/// Display ordinals are physical displays, with the main display first. They are not Spaces.
enum WorkflowDisplayPolicy {
    static let maximumDisplayIndex = 32
    static func resolvedIndex(requested: Int, displayCount: Int) -> Int {
        (1...max(1, displayCount)).contains(requested) ? requested : 1
    }
}

@MainActor enum DesktopWindowPlacement {
    static var screens: [NSScreen] {
        NSScreen.screens.sorted { lhs, rhs in
            let left = displayID(lhs), right = displayID(rhs)
            if left == CGMainDisplayID() { return right != left }
            if right == CGMainDisplayID() { return false }
            return left < right
        }
    }
    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func apply(to app: NSRunningApplication, displayIndex: Int?, fullscreen: Bool?) async throws {
        guard displayIndex != nil || fullscreen != nil else { return }
        guard AXIsProcessTrusted() else { throw ProviderError.message("Enable JustWisper in System Settings → Privacy & Security → Accessibility to place app windows.") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var selected: AXUIElement?
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard !app.isTerminated else { throw ProviderError.message("The app closed before its window was ready.") }
            if let window = attribute(kAXFocusedWindowAttribute, application), CFGetTypeID(window) == AXUIElementGetTypeID() {
                let candidate = window as! AXUIElement
                var pid: pid_t = 0
                if AXUIElementGetPid(candidate, &pid) == .success, pid == app.processIdentifier,
                   attribute(kAXRoleAttribute, candidate) as? String == kAXWindowRole {
                    selected = candidate; break
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let window = selected else { throw ProviderError.message("No app window became ready. Open a normal window in the chosen app and retry.") }
        let wasFullscreen = attribute("AXFullScreen", window) as? Bool ?? false
        if wasFullscreen && (displayIndex != nil || fullscreen == false) {
            try set("AXFullScreen", value: kCFBooleanFalse, window: window)
            try await waitFullscreen(false, window: window)
        }
        if let requested = displayIndex {
            let available = screens
            guard !available.isEmpty else { throw ProviderError.message("No display is available for window placement.") }
            let target = available[WorkflowDisplayPolicy.resolvedIndex(requested: requested, displayCount: available.count) - 1]
            let frame = target.visibleFrame
            let mainTop = available[0].frame.maxY
            var point = CGPoint(x: frame.minX, y: mainTop - frame.maxY)
            var size = CGSize(width: frame.width, height: frame.height)
            var needsResize = true
            if let raw = attribute(kAXSizeAttribute, window), CFGetTypeID(raw) == AXValueGetTypeID() {
                var current = CGSize.zero
                if AXValueGetValue(raw as! AXValue, .cgSize, &current) {
                    size = CGSize(width: min(current.width, frame.width), height: min(current.height, frame.height))
                    needsResize = size != current
                }
            }
            try Task.checkCancellation()
            if needsResize { try set(kAXSizeAttribute, value: AXValueCreate(.cgSize, &size)!, window: window) }
            try set(kAXPositionAttribute, value: AXValueCreate(.cgPoint, &point)!, window: window)
        }
        if fullscreen == true && (!wasFullscreen || displayIndex != nil) {
            try Task.checkCancellation()
            try set("AXFullScreen", value: kCFBooleanTrue, window: window)
            try await waitFullscreen(true, window: window)
        }
    }
    private static func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func set(_ name: String, value: CFTypeRef, window: AXUIElement) throws {
        try Task.checkCancellation()
        guard AXUIElementSetAttributeValue(window, name as CFString, value) == .success else {
            throw ProviderError.message("The app could not change its window's \(name == "AXFullScreen" ? "fullscreen state" : "position or size"). Check Accessibility access and use a normal, resizable app window.")
        }
    }
    private static func waitFullscreen(_ expected: Bool, window: AXUIElement) async throws {
        for _ in 0..<30 {
            try Task.checkCancellation()
            if attribute("AXFullScreen", window) as? Bool == expected {
                // Allow the public fullscreen transition to settle before moving the window.
                try await Task.sleep(for: .milliseconds(500)); return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ProviderError.message("The app's fullscreen transition did not finish. Leave fullscreen manually and retry.")
    }
}
