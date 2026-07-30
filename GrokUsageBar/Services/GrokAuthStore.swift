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

    /// True when the access token is missing an expiry or expires within `skew` seconds.
    func isExpiring(within skew: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow <= skew
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

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            return "No Grok session found. Run `grok login` first."
        case .authFileUnreadable:
            return "Could not read ~/.grok/auth.json."
        case .noSession:
            return "auth.json has no usable session."
        case .tokenExpired:
            return "Grok session expired. Run `grok login` again."
        case .malformedAuthFile:
            return "auth.json is not in the expected format."
        case .refreshUnavailable:
            return "Session has no refresh token. Run `grok login` again."
        case .refreshFailed(let message):
            return "Could not refresh Grok session: \(message)"
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
                authMode: entry["auth_mode"] as? String
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
        let temp = dir.appendingPathComponent(".auth.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: temp.path
            )
            // replaceItemAt is atomic on the same volume.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
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
