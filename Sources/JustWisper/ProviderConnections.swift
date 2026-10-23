import Foundation
import CryptoKit

struct ProviderConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: String = "rewrite"
    var endpoint: String
    var model: String

    /// A host change requires its own credential. Keys never belong in Codable configuration.
    var keychainAccount: String {
        "connection-\(id.uuidString.lowercased())-\(ProviderCredentialIdentity.originHash(endpoint))"
    }
    func validate() throws {
        guard ["speech", "rewrite"].contains(kind), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: endpoint) else {
            throw AppError.message("Give this connection a name, supported purpose, endpoint and model.")
        }
        try ProviderHTTP.validate(url)
    }
}

struct ResolvedProviderRoute {
    var settings: AppSettings
    var speechKey: String
    var rewriteKey: String
}

enum ModeProviderRouting {
    static func resolve(mode: DictationMode, settings: AppSettings, connections: [ProviderConnection], defaultSpeechKey: String,
                        defaultRewriteKey: String, loadKey: (String) throws -> String) throws -> ResolvedProviderRoute {
        var result = ResolvedProviderRoute(settings: settings, speechKey: defaultSpeechKey, rewriteKey: defaultRewriteKey)
        if let id = mode.speechConnectionID {
            guard let connection = connections.first(where: { $0.id == id && $0.kind == "speech" }) else { throw AppError.message("The speech connection selected by this mode is missing. Choose another connection in Modes.") }
            try connection.validate()
            result.settings.speechProvider = "cloud"
            result.settings.speechEndpoint = connection.endpoint
            result.settings.speechModel = connection.model
            result.speechKey = try loadKey(connection.keychainAccount)
        }
        if let id = mode.rewriteConnectionID {
            guard let connection = connections.first(where: { $0.id == id && $0.kind == "rewrite" }) else { throw AppError.message("The language connection selected by this mode is missing. Choose another connection in Modes.") }
            try connection.validate()
            result.settings.rewriteEndpoint = connection.endpoint
            result.settings.rewriteModel = connection.model
            result.rewriteKey = try loadKey(connection.keychainAccount)
        }
        result.settings = result.settings.resolving(mode: mode)
        return result
    }
}

/// Credentials belong to an origin, including its scheme and effective port.
/// Paths/model names can change without sharing a key with another server.
enum ProviderCredentialIdentity {
    static func originHash(_ endpoint: String) -> String {
        let url = URL(string: endpoint)
        let scheme = url?.scheme?.lowercased() ?? ""
        let port = url?.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        let origin = "\(scheme)://\(url?.host?.lowercased() ?? ""):\(port)"
        return SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func defaultAccount(kind: String, endpoint: String) -> String {
        "default-\(kind)-\(originHash(endpoint))"
    }
}
