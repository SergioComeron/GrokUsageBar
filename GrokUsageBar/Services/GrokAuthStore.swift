//
//  GrokAuthStore.swift
//  GrokUsageBar
//
//  Reads Grok Build's cached OAuth session from ~/.grok/auth.json.
//  Tokens stay on disk as Grok wrote them; we only load them into memory.
//

import Foundation

struct GrokSession: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var email: String?
    var userId: String?
    var teamId: String?
    var oidcIssuer: String?
    var oidcClientId: String?
    var authMode: String?
}

enum GrokAuthError: LocalizedError, Equatable {
    case authFileMissing
    case authFileUnreadable
    case noSession
    case tokenExpired
    case malformedAuthFile

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
        }
    }
}

enum GrokAuthStore {
    /// Default path used by Grok Build CLI.
    static var authFileURL: URL {
        if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"], !grokHome.isEmpty {
            return URL(fileURLWithPath: grokHome, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    /// Load the first session entry from auth.json (keys are issuer::client_id).
    static func loadSession(from url: URL = authFileURL) throws -> GrokSession {
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

        // Prefer a non-empty entry that looks like an OIDC/session record.
        for (_, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            guard let token = entry["key"] as? String, !token.isEmpty else { continue }

            var expiresAt: Date?
            if let expires = entry["expires_at"] as? String {
                expiresAt = ISO8601DateFormatter.grok.date(from: expires)
                    ?? ISO8601DateFormatter.grokFractional.date(from: expires)
            }

            return GrokSession(
                accessToken: token,
                refreshToken: entry["refresh_token"] as? String,
                expiresAt: expiresAt,
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

    static func hasSession(from url: URL = authFileURL) -> Bool {
        (try? loadSession(from: url)) != nil
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
