import Foundation
import Testing
@testable import JustWisper

struct DesktopGesturePolicyTests {
    @Test func overlappingHoldReleaseCannotStopTheAcceptedGesture() {
        var ownership = HoldRecordingOwnership()
        let ownershipResult1 = ownership.begin(.keyboard, available: true)
        #expect(ownershipResult1)
        let ownershipResult2 = ownership.begin(.mouse, available: true)
        #expect(!ownershipResult2)
        let ownershipResult3 = ownership.end(.mouse)
        #expect(!ownershipResult3)
        let ownershipResult4 = ownership.end(.keyboard)
        #expect(ownershipResult4)
        let ownershipResult5 = ownership.begin(.mouse, available: false)
        #expect(!ownershipResult5)
        let ownershipResult6 = ownership.end(.mouse)
        #expect(!ownershipResult6)
        let ownershipResult7 = ownership.begin(.mouse, available: true)
        #expect(ownershipResult7)
        ownership.clear() // Toggle stop or cancellation invalidates the old release.
        let ownershipResult8 = ownership.end(.mouse)
        #expect(!ownershipResult8)
        let ownershipResult9 = ownership.begin(.keyboard, available: true)
        #expect(ownershipResult9)
    }

    @Test func mouseBindingIgnoresPrimaryClicksAndUnpairedEvents() {
        for button in [0, 1, 5] {
            var gesture = MouseRecordingGesture(button: button, behavior: .hold)
            let result10 = gesture.receive(button: button, down: true)
            #expect(result10 == nil)
        }
        var gesture = MouseRecordingGesture(button: 3, behavior: .hold)
        let result11 = gesture.receive(button: 3, down: false)
        #expect(result11 == nil)
        let result12 = gesture.receive(button: 2, down: true)
        #expect(result12 == nil)
        let result13 = gesture.receive(button: 3, down: true)
        #expect(result13 == .beginHold)
        let result14 = gesture.receive(button: 3, down: true)
        #expect(result14 == nil)
        let result15 = gesture.receive(button: 2, down: false)
        #expect(result15 == nil)
        let result16 = gesture.receive(button: 3, down: false)
        #expect(result16 == .endHold)
        let result17 = gesture.receive(button: 3, down: false)
        #expect(result17 == nil)
        var toggle = MouseRecordingGesture(button: 2, behavior: .toggle)
        let result18 = toggle.receive(button: 2, down: true)
        #expect(result18 == .toggle)
        let result19 = toggle.receive(button: 2, down: true)
        #expect(result19 == nil)
        let result20 = toggle.receive(button: 2, down: false)
        #expect(result20 == nil)
        let result21 = toggle.receive(button: 2, down: true)
        #expect(result21 == .toggle)
    }

    @Test func clipboardEnableRestoreSensitiveChangesAndExpiryNeverBecomeFreshContext() {
        let now = Date(timeIntervalSince1970: 1000)
        let types = ["public.utf8-plain-text"]
        var tracker = RecentClipboardTracker()
        tracker.reset(changeCount: 10)
        tracker.observe(changeCount: 10, types: types, text: "Old clipboard", at: now)
        let result22 = tracker.recent(at: now)
        #expect(result22 == nil)
        tracker.observe(changeCount: 11, types: types, text: "New copy", at: now)
        let result23 = tracker.recent(at: now.addingTimeInterval(3))
        #expect(result23 == "New copy")
        let result24 = tracker.recent(at: now.addingTimeInterval(3.001))
        #expect(result24 == nil)
        tracker.observe(changeCount: 12, types: types, text: "Public", at: now)
        tracker.observe(changeCount: 13, types: types + ["org.nspasteboard.ConcealedType"], text: "Secret", at: now)
        let result25 = tracker.recent(at: now)
        #expect(result25 == nil)
        tracker.observe(changeCount: 14, types: types, text: "Public", at: now)
        tracker.reset(changeCount: 15) // JustWisper restores an earlier pasteboard.
        tracker.observe(changeCount: 15, types: types, text: "Restored", at: now)
        let result26 = tracker.recent(at: now)
        #expect(result26 == nil)
        tracker.observe(changeCount: 16, types: types, text: "Future", at: now)
        let result27 = tracker.recent(at: now.addingTimeInterval(-1))
        #expect(result27 == nil)
    }

    @Test func switcherNavigationWrapsAndEmptyModesHaveNoAction() {
        var empty = ModeSwitcherSelection(count: 0)
        empty.move(-1)
        #expect(empty.selectedIndex == nil)
        var modes = ModeSwitcherSelection(count: 3, selectedIndex: 0)
        modes.move(-1)
        #expect(modes.selectedIndex == 2)
        modes.move(1)
        #expect(modes.selectedIndex == 0)
        modes.move(7)
        #expect(modes.selectedIndex == 1)
        modes.move(-8)
        #expect(modes.selectedIndex == 2)
    }
}
