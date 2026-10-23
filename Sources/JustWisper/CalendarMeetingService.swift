import AppKit
import CoreAudio
import EventKit
import Foundation
import SwiftUI

struct CalendarMeeting: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendarName: String
    var meetingURL: URL?

    func suggestedNow(at now: Date = Date()) -> Bool {
        start <= now.addingTimeInterval(10 * 60) && end > now
    }
}

/// Calendar metadata stays in memory. Access is requested only by requestAccess().
@MainActor
final class CalendarMeetingService: ObservableObject {
    @Published private(set) var upcoming: [CalendarMeeting] = []
    @Published private(set) var authorizationText = "Connect Calendar to see upcoming meetings"
    @Published private(set) var isRequesting = false
    @Published private(set) var error: String?
    private var eventStore: EKEventStore?
    private var changeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Invoked by an explicit Connect Calendar action, never from initialization or refresh.
    func requestAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        error = nil
        defer { isRequesting = false }
        let store = eventStore ?? EKEventStore()
        eventStore = store
        do {
            let granted = try await store.requestFullAccessToEvents()
            if !granted { error = "Calendar access was not granted. You can change this in System Settings → Privacy & Security → Calendars." }
            refresh()
            if granted { startObserving() }
        } catch {
            self.error = "Could not connect Calendar: \(error.localizedDescription)"
            updateAuthorization()
        }
    }

    /// Refreshes already-authorized data; this function never requests permission.
    func refresh(now: Date = Date()) {
        updateAuthorization()
        guard hasAccess else { upcoming = []; return }
        let store = eventStore ?? EKEventStore()
        eventStore = store
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-2 * 3600), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(30)
            .map { event in
                CalendarMeeting(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    title: CapturedContext.sanitize(event.title, limit: 200) ?? "Meeting",
                    start: event.startDate, end: event.endDate,
                    calendarName: CapturedContext.sanitize(event.calendar.title, limit: 100) ?? "Calendar",
                    meetingURL: Self.meetingURL(event.url) ?? Self.meetingURL(event.location.flatMap(URL.init(string:))))
            }
    }

    /// May be called while showing the meeting view, after a previous explicit authorization.
    func startObserving() {
        guard hasAccess else { updateAuthorization(); return }
        refresh()
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopObserving() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        upcoming = []
    }

    private func updateAuthorization() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: authorizationText = "Calendar connected · upcoming 24 hours"
        case .notDetermined: authorizationText = "Connect Calendar to see upcoming meetings"
        case .denied: authorizationText = "Calendar access is off in System Settings"
        case .restricted: authorizationText = "Calendar access is restricted on this Mac"
        case .writeOnly: authorizationText = "Reading upcoming meetings requires full Calendar access"
        @unknown default: authorizationText = "Calendar authorization is unavailable"
        }
    }

    nonisolated static func meetingURL(_ url: URL?) -> URL? {
        guard let url, let host = ModeContextMatcher.host(from: url.absoluteString),
              ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// Input activity is stronger evidence than a running app, but cannot distinguish
/// a call from a meeting app's microphone test. Neither starts recording.
@MainActor
final class MeetingAppDetector: ObservableObject {
    @Published private(set) var openMeetingApps: [String] = []
    @Published private(set) var activeMicrophoneApps: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var activityTimer: Timer?
    private var siteHost: String?
    nonisolated private static let knownApps = ["us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams", "com.apple.FaceTime": "FaceTime", "com.cisco.webexmeetingsapp": "Webex", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord"]

    var statusText: String? {
        if !activeMicrophoneApps.isEmpty { return "Meeting app using microphone: " + activeMicrophoneApps.joined(separator: ", ") }
        guard !openMeetingApps.isEmpty else { return nil }
        return "Meeting app open: " + openMeetingApps.joined(separator: ", ")
    }
    var evidenceText: String {
        activeMicrophoneApps.isEmpty ? "An open app does not confirm that a call is active." : "macOS reports active microphone input. A microphone test can also cause this suggestion; recording starts only when you choose Record."
    }

    func start() {
        refresh()
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActivity() }
        }
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        activityTimer?.invalidate(); activityTimer = nil
        openMeetingApps = []
        activeMicrophoneApps = []
        siteHost = nil
    }

    func refresh(siteHost: String? = nil) {
        self.siteHost = siteHost
        var names = Set(NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.flatMap { Self.knownApps[$0] } })
        if let siteHost {
            if siteHost == "meet.google.com" { names.insert("Google Meet page") }
            if siteHost == "teams.microsoft.com" || siteHost == "teams.live.com" { names.insert("Teams page") }
        }
        openMeetingApps = names.sorted()
        refreshActivity()
    }

    private func refreshActivity() {
        activeMicrophoneApps = Self.activeMeetingNames(inputBundleIDs: Self.microphoneProcessBundleIDs())
    }

    nonisolated static func activeMeetingNames(inputBundleIDs: [String]) -> [String] {
        Array(Set(inputBundleIDs.compactMap { bundle in
            knownApps.first { bundle == $0.key || bundle.hasPrefix($0.key + ".") }?.value
        })).sorted()
    }

    /// Reads process activity flags only. It neither opens an audio stream nor
    /// requests microphone or system-audio recording permission.
    private static func microphoneProcessBundleIDs() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr,
              byteCount > 0, byteCount <= 1_000_000,
              Int(byteCount) % MemoryLayout<AudioObjectID>.size == 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        let result = processes.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, storage.baseAddress!)
        }
        guard result == noErr else { return [] }
        return processes.prefix(Int(byteCount) / MemoryLayout<AudioObjectID>.size).compactMap { process in
            var active: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &property, 0, nil, &size, &active) == noErr, active != 0 else { return nil }
            property.mSelector = kAudioProcessPropertyBundleID
            var bundle: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &property, 0, nil, &size, &bundle) == noErr, let bundle else { return nil }
            return bundle.takeRetainedValue() as String
        }
    }
}
