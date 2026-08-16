//
//  GrokDeviceLogin.swift
//  GrokUsageBar
//
//  Official xAI device-code flow (same public client as `grok login --device-auth`).
//  Completing it writes ~/.grok/auth.json so Grok Build and this app share the session.
//

import Foundation

enum GrokDeviceLogin {
    static let issuer = "https://auth.x.ai"
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let scopes = "openid profile email offline_access api:access grok-cli:access"

    private static let deviceURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let userInfoURL = URL(string: "https://auth.x.ai/oauth2/userinfo")!
    private static let userAgent = "GrokUsageBar/0.2.3"

    struct Pending: Equatable, Sendable {
        var deviceCode: String
        var userCode: String
        var verificationURL: URL
        var expiresAt: Date
        var interval: TimeInterval
    }

    /// Request a user code and verification URL. Does not open the browser.
    static func start() async throws -> Pending {
        var request = URLRequest(url: deviceURL)
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        request.httpBody = form([
            "client_id": clientID,
            "scope": scopes,
        ])

        let json = try await jsonObject(for: request)
        if let error = json["error"] as? String {
            let detail = (json["error_description"] as? String) ?? error
            throw GrokAuthError.loginFailed(detail)
        }
        guard
            let deviceCode = json["device_code"] as? String, !deviceCode.isEmpty,
            let userCode = json["user_code"] as? String, !userCode.isEmpty
        else {
            throw GrokAuthError.loginFailed("Device-code response missing codes.")
        }

        let urlString = (json["verification_uri_complete"] as? String)
            ?? (json["verification_uri"] as? String)
            ?? "https://accounts.x.ai/oauth2/device"
        guard let url = URL(string: urlString) else {
            throw GrokAuthError.loginFailed("Invalid verification URL.")
        }

        let expiresIn = number(json["expires_in"]) ?? 1800
        let interval = max(1, number(json["interval"]) ?? 5)
        return Pending(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            expiresAt: Date().addingTimeInterval(expiresIn),
            interval: interval
        )
    }

    /// Poll until the user finishes in the browser, then persist the session.
    static func waitForSession(_ pending: Pending) async throws -> GrokSession {
        var interval = pending.interval
        while Date() < pending.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()

            do {
                let session = try await exchange(pending)
                try GrokAuthStore.saveSession(session)
                return session
            } catch Exchange.pending {
                continue
            } catch Exchange.slowDown {
                interval += 5
                continue
            }
        }
        throw GrokAuthError.loginFailed("Sign-in timed out. Try again.")
    }

    // MARK: - Token exchange

    private enum Exchange: Error {
        case pending
        case slowDown
    }

    private static func exchange(_ pending: Pending) async throws -> GrokSession {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        request.httpBody = form([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": pending.deviceCode,
            "client_id": clientID,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GrokAuthError.loginFailed("No HTTP response.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let oauthError = json["error"] as? String

        if oauthError == "authorization_pending" { throw Exchange.pending }
        if oauthError == "slow_down" { throw Exchange.slowDown }
        if oauthError == "expired_token" || oauthError == "access_denied" {
            throw GrokAuthError.loginFailed(oauthError == "access_denied"
                ? "Sign-in was denied."
                : "Sign-in code expired. Try again.")
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = (json["error_description"] as? String)
                ?? oauthError
                ?? "HTTP \(http.statusCode)"
            throw GrokAuthError.loginFailed(detail)
        }

        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw GrokAuthError.loginFailed("Token response missing access_token.")
        }
        let refresh = json["refresh_token"] as? String
        let expiresIn = number(json["expires_in"]) ?? 21600
        let profile = await userProfile(accessToken: access)

        return GrokSession(
            entryKey: "\(issuer)::\(clientID)",
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: profile.email,
            userId: profile.userId,
            teamId: profile.teamId,
            oidcIssuer: issuer,
            oidcClientId: clientID,
            authMode: "oidc",
            givenName: profile.givenName,
            familyName: profile.familyName
        )
    }

    private struct Profile {
        var email: String?
        var userId: String?
        var teamId: String?
        var givenName: String?
        var familyName: String?
    }

    private static func userProfile(accessToken: String) async -> Profile {
        var profile = Profile()
        if let jwt = GrokSession.unverifiedJWTPayload(accessToken) {
            profile.email = jwt["email"] as? String
            profile.userId = jwt["sub"] as? String
                ?? jwt["user_id"] as? String
                ?? jwt["principal_id"] as? String
            profile.teamId = jwt["team_id"] as? String
            profile.givenName = jwt["given_name"] as? String
            profile.familyName = jwt["family_name"] as? String
        }

        var request = URLRequest(url: userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let json = try? await jsonObject(for: request) {
            profile.email = (json["email"] as? String) ?? profile.email
            profile.userId = (json["sub"] as? String) ?? profile.userId
            profile.givenName = (json["given_name"] as? String) ?? profile.givenName
            profile.familyName = (json["family_name"] as? String) ?? profile.familyName
        }
        return profile
    }

    // MARK: - HTTP

    private static func applyCommonHeaders(_ request: inout URLRequest) {
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("grok-build", forHTTPHeaderField: "x-grok-client-surface")
    }

    private static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func jsonObject(for request: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw GrokAuthError.loginCancelled
        } catch {
            throw GrokAuthError.loginFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokAuthError.loginFailed("No HTTP response.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200...299).contains(http.statusCode), json["error"] == nil {
            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GrokAuthError.loginFailed(snippet.isEmpty ? "HTTP \(http.statusCode)" : snippet)
        }
        return json
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return TimeInterval(i) }
        return nil
    }
}
