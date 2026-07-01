import Foundation
import Security

/// Strava OAuth credentials for the bring-your-own-app model: the user pastes their OWN Strava API
/// application's client id + secret (created at strava.com/settings/api), and we obtain + refresh the
/// OAuth tokens against it. Nothing is embedded in the binary — same "private by default, BYO-key"
/// stance as the AI Coach. Persisted as one JSON blob in the Keychain, never UserDefaults / plist.
struct StravaCredentials: Codable, Equatable {
    var clientId: String
    var clientSecret: String
    var accessToken: String?
    var refreshToken: String?
    /// Unix seconds at which `accessToken` expires (Strava returns `expires_at`).
    var expiresAt: TimeInterval?

    /// The user has configured their Strava app (can start the OAuth connect flow).
    var hasApp: Bool {
        !clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A live connection: we hold usable tokens.
    var isConnected: Bool {
        (accessToken?.isEmpty == false) && (refreshToken?.isEmpty == false)
    }

    /// True when the access token is missing or within 5 minutes of expiry — refresh before using it.
    func needsRefresh(now: TimeInterval) -> Bool {
        guard accessToken?.isEmpty == false, let exp = expiresAt else { return true }
        return now >= exp - 300
    }
}

/// Keychain wrapper for `StravaCredentials` — one generic-password item, JSON-encoded value.
enum StravaCredentialStore {
    private static let service = "com.noop.strava"
    private static let account = "oauth"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> StravaCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(StravaCredentials.self, from: data) else { return nil }
        return creds
    }

    @discardableResult
    static func save(_ creds: StravaCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        SecItemDelete(baseQuery as CFDictionary)   // always insert a single fresh value
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
