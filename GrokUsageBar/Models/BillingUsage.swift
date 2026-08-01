//
//  BillingUsage.swift
//  GrokUsageBar
//
//  Snapshot aligned with Grok Build /usage:
//  - Primary: weekly creditUsagePercent from GET /v1/billing?format=credits
//  - Secondary (optional): monthly unit pool from GET /v1/billing
//

import Foundation

/// One billing cycle in the usage history (typically a calendar month).
struct UsageHistoryPoint: Equatable, Sendable, Identifiable {
    var year: Int
    var month: Int
    var totalUsed: Double
    var isCurrent: Bool

    var id: String { "\(year)-\(month)-\(isCurrent ? "c" : "h")" }

    /// Short label like "Jul".
    var monthLabel: String {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else {
            return String(format: "%02d", month)
        }
        return date.formatted(.dateTime.month(.abbreviated))
    }
}

/// Per-product share of the unified weekly quota (GrokBuild, GrokChat, …).
struct ProductUsageShare: Equatable, Sendable, Identifiable {
    var product: String
    var usagePercent: Double

    var id: String { product }

    var displayName: String {
        switch product {
        case "GrokBuild": return "Build"
        case "GrokImagine": return "Imagine"
        case "GrokVoice": return "Voice"
        case "GrokChat": return "Chat"
        default: return product.replacingOccurrences(of: "Grok", with: "")
        }
    }
}

enum UsagePeriodKind: String, Equatable, Sendable {
    case weekly
    case monthly
    case unknown

    var shortLabel: String {
        switch self {
        case .weekly: return "week"
        case .monthly: return "month"
        case .unknown: return "period"
        }
    }

    var titleLabel: String {
        switch self {
        case .weekly: return "Weekly limit"
        case .monthly: return "Monthly limit"
        case .unknown: return "Usage limit"
        }
    }
}

/// Plan inferred from OAuth JWT `tier` and/or billing fields.
/// Marketing ladder used by Grok Build: Free / X Basic → SuperGrok → SuperGrok Heavy.
struct GrokSubscriptionPlan: Equatable, Sendable {
    /// Raw integer from JWT `tier` when available.
    var rawTier: Int?
    /// Human label for the menu (e.g. “SuperGrok”, “SuperGrok Heavy”).
    var displayName: String
    /// Short badge for the menu bar (e.g. “SG”, “Heavy”).
    var shortBadge: String

    /// Best-effort map of JWT tier → product name.
    /// Confirmed in the wild: tier 1 with SuperGrok-class limits (~15k monthly units).
    static func resolve(
        jwtTier: Int?,
        apiDisplayName: String? = nil,
        apiTierKey: String? = nil
    ) -> GrokSubscriptionPlan? {
        if let api = apiDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !api.isEmpty {
            return GrokSubscriptionPlan(
                rawTier: jwtTier,
                displayName: api,
                shortBadge: shortBadge(forDisplay: api, tier: jwtTier)
            )
        }
        if let key = apiTierKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let name = prettyTierKey(key)
            return GrokSubscriptionPlan(
                rawTier: jwtTier,
                displayName: name,
                shortBadge: shortBadge(forDisplay: name, tier: jwtTier)
            )
        }
        guard let tier = jwtTier else { return nil }
        let name: String
        switch tier {
        case 0: name = "Free"
        case 1: name = "SuperGrok"
        case 2: name = "SuperGrok Heavy"
        case 3: name = "Enterprise"
        default: name = "Tier \(tier)"
        }
        return GrokSubscriptionPlan(
            rawTier: tier,
            displayName: name,
            shortBadge: shortBadge(forDisplay: name, tier: tier)
        )
    }

    private static func prettyTierKey(_ key: String) -> String {
        let k = key.uppercased()
        if k.contains("HEAVY") { return "SuperGrok Heavy" }
        if k.contains("SUPER") { return "SuperGrok" }
        if k.contains("BASIC") { return "X Basic" }
        if k.contains("FREE") { return "Free" }
        if k.contains("ENTERPRISE") || k.contains("TEAM") { return "Enterprise" }
        return key
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func shortBadge(forDisplay name: String, tier: Int?) -> String {
        let n = name.lowercased()
        if n.contains("heavy") { return "Heavy" }
        if n.contains("super") { return "SG" }
        if n.contains("basic") { return "Basic" }
        if n.contains("free") { return "Free" }
        if n.contains("enterprise") { return "Ent" }
        if let tier { return "T\(tier)" }
        return "Plan"
    }
}

/// Snapshot of account usage. **Primary metric is the weekly limit** (what `/usage` shows).
struct BillingUsage: Equatable, Sendable {
    /// 0…100 — same number as CLI “Weekly limit: N%” (`creditUsagePercent`).
    var creditUsagePercent: Double
    /// Weekly vs monthly (from `currentPeriod.type` when using format=credits).
    var periodKind: UsagePeriodKind
    var includedUsed: Double?
    var totalUsed: Double?
    var monthlyLimit: Double?
    /// Monthly credit units used (from plain `/billing`), when available.
    var monthlyUsed: Double?
    var prepaidBalance: Double?
    var onDemandCap: Double?
    var onDemandUsed: Double?
    var billingPeriodStart: Date?
    var billingPeriodEnd: Date?
    var isUnifiedBillingUser: Bool?
    /// SuperGrok / Heavy / … when we can resolve it (JWT + optional API fields).
    var subscription: GrokSubscriptionPlan?
    var productUsage: [ProductUsageShare]
    /// Past cycles (and usually the current one last), oldest → newest.
    var history: [UsageHistoryPoint]
    /// When this snapshot was fetched locally.
    var fetchedAt: Date

    static let placeholder = BillingUsage(
        creditUsagePercent: 0,
        periodKind: .unknown,
        includedUsed: nil,
        totalUsed: nil,
        monthlyLimit: nil,
        monthlyUsed: nil,
        prepaidBalance: nil,
        onDemandCap: nil,
        onDemandUsed: nil,
        billingPeriodStart: nil,
        billingPeriodEnd: nil,
        isUnifiedBillingUser: nil,
        subscription: nil,
        productUsage: [],
        history: [],
        fetchedAt: .distantPast
    )

    /// Compact label for the menu bar and panel.
    /// Under 10% keeps one decimal so low burn rates stay visible (e.g. 0.7%).
    var percentDisplay: String {
        Self.formatPercent(creditUsagePercent)
    }

    /// e.g. "46% week" for the menu bar.
    var menuBarDisplay: String {
        "\(percentDisplay) \(periodKind == .weekly ? "wk" : periodKind.shortLabel)"
    }

    var usageLevel: UsageLevel {
        switch creditUsagePercent {
        case ..<50: return .ok
        case ..<80: return .warn
        default: return .high
        }
    }

    /// Values for the sparkline, oldest → newest.
    var sparklineValues: [Double] {
        history.map(\.totalUsed)
    }

    /// Absolute reset time, e.g. “6 August, 10:22”.
    var nextResetDisplay: String? {
        guard let end = billingPeriodEnd else { return nil }
        return end.formatted(
            .dateTime.day().month(.wide).hour().minute()
        )
    }

    /// Relative countdown, e.g. “in 5 days” / “in 3 hours” / “soon”.
    var resetInDisplay: String? {
        guard let end = billingPeriodEnd else { return nil }
        let seconds = end.timeIntervalSinceNow
        if seconds <= 0 { return "any moment" }
        let hours = seconds / 3600
        if hours < 1 {
            let mins = max(1, Int((seconds / 60).rounded()))
            return "in \(mins) min"
        }
        if hours < 48 {
            let h = Int(hours.rounded())
            return h == 1 ? "in 1 hour" : "in \(h) hours"
        }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    /// Full window in local time, e.g. “30 Jul – 6 Aug”.
    var periodRangeDisplay: String? {
        guard let start = billingPeriodStart, let end = billingPeriodEnd else { return nil }
        let s = start.formatted(.dateTime.day().month(.abbreviated))
        let e = end.formatted(.dateTime.day().month(.abbreviated))
        return "\(s) – \(e)"
    }

    /// One-line summary for the panel footer / tooltip.
    /// e.g. “30 Jul – 6 Aug · resets in 5 days (6 Aug, 10:22)”.
    var periodSummaryDisplay: String? {
        var parts: [String] = []
        if let range = periodRangeDisplay {
            parts.append(range)
        }
        if let rel = resetInDisplay, let abs = nextResetDisplay {
            parts.append("resets \(rel) (\(abs))")
        } else if let abs = nextResetDisplay {
            parts.append("resets \(abs)")
        } else if let rel = resetInDisplay {
            parts.append("resets \(rel)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formatPercent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 1000)
        let shown = min(clamped, 100)
        if shown >= 10 || shown == 0 {
            return String(format: "%.0f%%", shown)
        }
        return String(format: "%.1f%%", shown)
    }
}

enum UsageLevel: Equatable {
    case ok, warn, high, unknown
}

enum UsageLoadState: Equatable {
    case idle
    case loading
    case loaded(BillingUsage)
    case failed(String)
    case needsLogin
}
