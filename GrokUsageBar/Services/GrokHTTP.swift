//
//  GrokHTTP.swift
//  GrokUsageBar
//
//  Shared request metadata. The version comes from the app bundle
//  (MARKETING_VERSION / CFBundleShortVersionString) so it does not drift
//  from the binary the way the old hardcoded "0.1" / "0.2" strings did.
//

import Foundation

enum GrokHTTP {
    /// `GrokUsageBar/<marketing version>`, or `GrokUsageBar/dev` when the
    /// bundle has no short version (tests, `swift test`).
    static func userAgent(marketingVersion: String?) -> String {
        let trimmed = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = trimmed.isEmpty ? "dev" : trimmed
        return "GrokUsageBar/\(version)"
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return userAgent(marketingVersion: version)
    }
}
