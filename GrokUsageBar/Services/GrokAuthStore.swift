//
//  GrokAuthStore.swift
//  GrokUsageBar
//
//  Reads Grok Build's cached OAuth session from ~/.grok/auth.json and refreshes
//  it via the OIDC token endpoint (same grant the CLI uses).
//

import Foundation

struct GrokSession: Equatable, Sendable {
    /// Map key in auth.json (typically `issuer::client_id`).
    var entryKey: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var email: String?
    var userId: String?
    var teamId: String?
    var oidcIssuer: String?
    var oidcClientId: String?
    var authMode: String?
    var givenName: String?
    var familyName: String?

    /// True when the access token is missing an expiry or expires within `skew` seconds.
    func isExpiring(within skew: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow <= skew
    }

    /// Subscription tier claim from the OAuth access JWT (`tier`), when present.
    /// xAI encodes plan level as an integer (1 ≈ SuperGrok, 5 ≈ SuperGrok Heavy).
    var jwtSubscriptionTier: Int? {
        Self.unverifiedJWTPayload(accessToken)?["tier"] as? Int
            ?? (Self.unverifiedJWTPayload(accessToken)?["tier"] as? Double).map(Int.init)
            ?? (Self.unverifiedJWTPayload(accessToken)?["tier"] as? String).flatMap(Int.init)
    }

    /// Unverified JWT payload (header.payload.sig) — only used for non-sensitive display claims.
    static func unverifiedJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 { b64.append(String(repeating: "=", count: pad)) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

enum GrokAuthError: LocalizedError, Equatable {
    case authFileMissing
    case authFileUnreadable
    case noSession
    case tokenExpired
    case malformedAuthFile
    case refreshUnavailable
    case refreshFailed(String)
    case loginFailed(String)
    case loginCancelled

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            return "No Grok session. Sign in from the menu."
        case .authFileUnreadable:
            return "Could not read ~/.grok/auth.json."
        case .noSession:
            return "auth.json has no usable session."
        case .tokenExpired:
            return "Grok session expired. Sign in again."
        case .malformedAuthFile:
            return "auth.json is not in the expected format."
        case .refreshUnavailable:
            return "Session has no refresh token. Sign in again."
        case .refreshFailed(let message):
            return "Could not refresh Grok session: \(message)"
        case .loginFailed(let message):
            return message
        case .loginCancelled:
            return "Sign-in cancelled."
        }
    }
}

enum GrokAuthStore {
    /// Refresh when fewer than this many seconds remain (5 minutes).
    static let refreshSkew: TimeInterval = 300

    /// Default path used by Grok Build CLI.
    static var authFileURL: URL {
        if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"], !grokHome.isEmpty {
            return URL(fileURLWithPath: grokHome, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    /// Load the first session entry from auth.json.
    static func loadSession(from url: URL = authFileURL) throws -> GrokSession {
        let root = try readRoot(from: url)

        for (entryKey, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            guard let token = entry["key"] as? String, !token.isEmpty else { continue }

            return GrokSession(
                entryKey: entryKey,
                accessToken: token,
                refreshToken: entry["refresh_token"] as? String,
                expiresAt: parseExpiry(entry["expires_at"] as? String),
                email: entry["email"] as? String,
                userId: entry["user_id"] as? String ?? entry["principal_id"] as? String,
                teamId: entry["team_id"] as? String,
                oidcIssuer: entry["oidc_issuer"] as? String,
                oidcClientId: entry["oidc_client_id"] as? String,
                authMode: entry["auth_mode"] as? String,
                givenName: entry["first_name"] as? String,
                familyName: entry["last_name"] as? String
            )
        }

        throw GrokAuthError.noSession
    }

    /// Session with a still-valid access token, refreshing via OIDC when needed.
    static func validSession(
        from url: URL = authFileURL,
        skew: TimeInterval = refreshSkew,
        forceRefresh: Bool = false
    ) async throws -> GrokSession {
        var session = try loadSession(from: url)
        if forceRefresh || session.isExpiring(within: skew) {
            session = try await refresh(session, authFileURL: url)
        }
        return session
    }

    static func hasSession(from url: URL = authFileURL) -> Bool {
        (try? loadSession(from: url)) != nil
    }

    // MARK: - Refresh

    /// Exchange `refresh_token` at `{issuer}/oauth2/token` and persist the new tokens.
    static func refresh(
        _ session: GrokSession,
        authFileURL url: URL = authFileURL
    ) async throws -> GrokSession {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw GrokAuthError.refreshUnavailable
        }
        guard let clientId = session.oidcClientId, !clientId.isEmpty else {
            throw GrokAuthError.refreshUnavailable
        }
        let issuer = (session.oidcIssuer?.isEmpty == false) ? session.oidcIssuer! : "https://auth.x.ai"
        guard let tokenURL = URL(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth2/token") else {
            throw GrokAuthError.refreshFailed("Invalid OIDC issuer.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GrokUsageBar/0.1", forHTTPHeaderField: "User-Agent")

        var body: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        var components = URLComponents()
        components.queryItems = body
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GrokAuthError.refreshFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrokAuthError.refreshFailed("No HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let short = snippet.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(snippet.prefix(160))"
            if http.statusCode == 400 || http.statusCode == 401 {
                throw GrokAuthError.tokenExpired
            }
            throw GrokAuthError.refreshFailed(String(short))
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            !accessToken.isEmpty
        else {
            throw GrokAuthError.refreshFailed("Token response missing access_token.")
        }

        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? refreshToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
            ?? 21600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        var updated = session
        updated.accessToken = accessToken
        updated.refreshToken = newRefresh
        updated.expiresAt = expiresAt

        try persistTokens(
            entryKey: session.entryKey,
            accessToken: accessToken,
            refreshToken: newRefresh,
            expiresAt: expiresAt,
            to: url
        )

        return updated
    }

    // MARK: - Persistence

    /// Write a full session (in-app login). Merges into existing auth.json.
    static func saveSession(_ session: GrokSession, to url: URL = authFileURL) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            root = (try? readRoot(from: url)) ?? [:]
        }
        var entry = (root[session.entryKey] as? [String: Any]) ?? [:]
        if entry["create_time"] == nil {
            entry["create_time"] = ISO8601DateFormatter.grokFractional.string(from: Date())
        }
        entry["auth_mode"] = session.authMode ?? "oidc"
        entry["key"] = session.accessToken
        entry["refresh_token"] = session.refreshToken ?? ""
        if let expiresAt = session.expiresAt {
            entry["expires_at"] = ISO8601DateFormatter.grokFractional.string(from: expiresAt)
        }
        entry["oidc_issuer"] = session.oidcIssuer ?? GrokDeviceLogin.issuer
        entry["oidc_client_id"] = session.oidcClientId ?? GrokDeviceLogin.clientID
        if let email = session.email { entry["email"] = email }
        if let userId = session.userId {
            entry["user_id"] = userId
            entry["principal_id"] = userId
            entry["principal_type"] = "User"
        }
        if let teamId = session.teamId { entry["team_id"] = teamId }
        if let given = session.givenName { entry["first_name"] = given }
        if let family = session.familyName { entry["last_name"] = family }
        root[session.entryKey] = entry

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: url, mode: 0o600)
    }

    /// Same as `grok logout`: drop the cached session file.
    static func signOut(from url: URL = authFileURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Update only token fields on the existing entry; keep everything else intact.
    private static func persistTokens(
        entryKey: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        to url: URL
    ) throws {
        var root = try readRoot(from: url)
        guard var entry = root[entryKey] as? [String: Any] else {
            throw GrokAuthError.noSession
        }
        entry["key"] = accessToken
        entry["refresh_token"] = refreshToken
        entry["expires_at"] = ISO8601DateFormatter.grokFractional.string(from: expiresAt)
        root[entryKey] = entry

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: url, mode: 0o600)
    }

    private static func readRoot(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokAuthError.authFileMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GrokAuthError.authFileUnreadable
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokAuthError.malformedAuthFile
        }
        return root
    }

    private static func atomicWrite(_ data: Data, to url: URL, mode: UInt16) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path
        )
        let temp = dir.appendingPathComponent(".auth.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: temp.path
            )
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw GrokAuthError.authFileUnreadable
        }
    }

    private static func parseExpiry(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter.grokFractional.date(from: raw)
            ?? ISO8601DateFormatter.grok.date(from: raw)
    }
}

private extension ISO8601DateFormatter {
    static let grok: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let grokFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
