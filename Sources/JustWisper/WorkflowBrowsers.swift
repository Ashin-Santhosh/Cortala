import AppKit
import Foundation

/// Profile identifiers come from browser-owned metadata; workflow JSON never supplies a filesystem path.
enum WorkflowBrowsers {
    struct Profile: Identifiable { var id: String; var name: String }
    static let names = ["com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "com.google.Chrome.beta": "Chrome Beta", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "Brave", "org.chromium.Chromium": "Chromium", "org.mozilla.firefox": "Firefox"]
    static var identifiers: [String] { names.keys.sorted() }
    static func supportsProfiles(_ id: String) -> Bool { roots[id] != nil || id == "org.mozilla.firefox" }
    static let roots = ["com.google.Chrome": "Google/Chrome", "com.google.Chrome.beta": "Google/Chrome Beta", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "BraveSoftware/Brave-Browser", "org.chromium.Chromium": "Chromium"]
    static func profiles(_ id: String, support: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")) -> [Profile] {
        if let root = roots[id] {
            let base = support.appendingPathComponent(root)
            guard let data = try? Data(contentsOf: base.appendingPathComponent("Local State")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profile = state["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
            return cache.compactMap { key, value in
                guard safeIdentifier(key), FileManager.default.fileExists(atPath: base.appendingPathComponent(key).path) else { return nil }
                return Profile(id: key, name: (value["name"] as? String ?? key) + " (\(key))")
            }.sorted { $0.id < $1.id }
        }
        if id == "org.mozilla.firefox", let ini = try? String(contentsOf: support.appendingPathComponent("Firefox/profiles.ini"), encoding: .utf8) {
            return ini.components(separatedBy: "[").compactMap { section in
                guard section.hasPrefix("Profile") else { return nil }
                let entries = section.components(separatedBy: .newlines).compactMap { line -> (String, String)? in
                    let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? (pair[0], pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                }
                let values = Dictionary(entries, uniquingKeysWith: { first, _ in first })
                guard let name = values["Name"], safeIdentifier(name), let profilePath = values["Path"] else { return nil }
                let directory = values["IsRelative"] == "1" ? support.appendingPathComponent("Firefox").appendingPathComponent(profilePath) : URL(fileURLWithPath: profilePath)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return Profile(id: name, name: name)
            }
        }
        return []
    }
    static func safeIdentifier(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 && !value.contains("/") && !value.contains("\\") && !value.contains("\0") && value != "." && value != ".." }
    @MainActor static func configuration(browser: String, profile: String?, support: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")) throws -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        if let profile {
            guard profiles(browser, support: support).contains(where: { $0.id == profile }) else { throw ProviderError.message("The selected browser profile is missing. Choose an available profile or Browser default in the workflow editor.") }
            config.arguments = browser == "org.mozilla.firefox" ? ["-P", profile] : ["--profile-directory=\(profile)"]
            // Launch Services must deliver command-line profile arguments even when the browser is already running.
            config.createsNewApplicationInstance = true
        }
        return config
    }
    @MainActor static func open(_ url: URL, browser: String?, profile: String?) async throws {
        guard let browser else {
            guard profile == nil, NSWorkspace.shared.open(url) else { throw ProviderError.message("Could not open the default browser.") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else { throw ProviderError.message("The selected browser is not installed. Choose another browser in the workflow editor.") }
        let config = try configuration(browser: browser, profile: profile)
        if supportsProfiles(browser) {
            config.createsNewApplicationInstance = true
            config.arguments += [browser == "org.mozilla.firefox" ? "-new-tab" : "--new-tab", url.absoluteString]
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
        } else {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        }
    }
}
