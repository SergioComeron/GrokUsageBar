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
/// Marketing ladder on x.ai/pricing: Free → Lite → SuperGrok → Plus → Heavy → Business → Enterprise.
struct GrokSubscriptionPlan: Equatable, Sendable {
    /// Raw integer from JWT `tier` when available.
    var rawTier: Int?
    /// Human label for the menu (e.g. “SuperGrok”, “SuperGrok Heavy”).
    var displayName: String
    /// Short badge for the menu bar (e.g. “SG”, “Heavy”).
    var shortBadge: String

    /// Best-effort map of JWT tier → product name.
    /// Confirmed from this account: 1 = SuperGrok, 5 = SuperGrok Heavy.
    /// Billing `?format=credits` does not currently send `subscriptionTier` /
    /// `subscriptionTierDisplay`, and `/v1/settings` still reports
    /// "SuperGrok Heavy" after a move to The X Subscription Ultra.
    /// The JWT `tier` claim is also unchanged (Ultra keeps 5). The pair
    /// `billingSystem=BILLING_SYSTEM_COMMERCE` + `tier=SUPER_GROK_PRO`
    /// from `GET https://grok.com/rest/subscriptions` is what identifies
    /// Ultra; that mapping wins over the stale display name.
    /// Tier 2 is also labelled SuperGrok Heavy, but that mapping is unconfirmed:
    /// nothing in the billing payload or in the CLI source we checked identifies
    /// JWT tier 2. Leave the label until a real tier-2 token shows otherwise.
    static func resolve(
        jwtTier: Int?,
        apiDisplayName: String? = nil,
        apiTierKey: String? = nil,
        commerceTier: String? = nil,
        commerceBillingSystem: String? = nil
    ) -> GrokSubscriptionPlan? {
        if let name = xSubscriptionDisplayName(tier: commerceTier, billingSystem: commerceBillingSystem) {
            return GrokSubscriptionPlan(
                rawTier: jwtTier,
                displayName: name,
                shortBadge: shortBadge(forDisplay: name, tier: jwtTier)
            )
        }
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
        case 5: name = "SuperGrok Heavy"
        case 2:
            // Unconfirmed. Same label as tier 5 until a captured tier-2 token says otherwise.
            name = "SuperGrok Heavy"
        case 3: name = "Enterprise"
        default: name = "Tier \(tier)"
        }
        return GrokSubscriptionPlan(
            rawTier: tier,
            displayName: name,
            shortBadge: shortBadge(forDisplay: name, tier: tier)
        )
    }

    /// The X Subscription name for a commerce-billed grok.com subscription.
    /// The tier enums were not renamed with the bundle, so the same value
    /// still names a legacy SuperGrok plan; the caller must already know
    /// the billing system is commerce. Only verified pairs are listed.
    static func xSubscriptionDisplayName(tier: String?, billingSystem: String?) -> String? {
        guard let billingSystem,
              billingSystem == "BILLING_SYSTEM_COMMERCE",
              let tier else { return nil }
        let normalized = tier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "SUBSCRIPTION_TIER_", with: "")
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        // Verified 2026-11-27 on this account after accounts.x.ai/unify:
        // Ultra keeps SUPER_GROK_PRO. grok.com/overview labels it "Ultra".
        case "SUPER_GROK_PRO":
            return "Ultra"
        default:
            return nil
        }
    }

    private static func prettyTierKey(_ key: String) -> String {
        let k = key.uppercased()
        if k.contains("ULTRA") { return "Ultra" }
        if k.contains("HEAVY") { return "SuperGrok Heavy" }
        if k.contains("PLUS") { return "SuperGrok Plus" }
        if k.contains("LITE") { return "SuperGrok Lite" }
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
        if n.contains("ultra") { return "Ultra" }
        if n.contains("heavy") { return "Heavy" }
        if n.contains("plus") { return "Plus" }
        if n.contains("lite") { return "Lite" }
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
    /// SuperGrok / Heavy / Ultra / … when we can resolve it (commerce
    /// subscriptions list, then JWT + optional API fields).
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

    /// True when this snapshot belongs to a window that has already ended.
    /// A missing end date is treated as still current so a failed refresh can
    /// keep the last number instead of wiping the bar.
    func billingWindowHasEnded(at now: Date = Date()) -> Bool {
        guard let end = billingPeriodEnd else { return false }
        return end < now
    }

    /// Pace against this account's window. Nil when the API didn't send start and end.
    func pace(at now: Date = Date()) -> UsagePace? {
        guard let start = billingPeriodStart, let end = billingPeriodEnd else { return nil }
        return UsagePace.evaluate(
            actualPercent: creditUsagePercent,
            periodStart: start,
            periodEnd: end,
            now: now
        )
    }

    /// Plain `/billing` currently returns zeros for the monthly pool. Hide that
    /// placeholder instead of drawing "0 / 0" and a flat chart. A real limit
    /// (non-zero `monthlyLimit`) still shows, even if this period's use is 0.
    var monthlyFiguresAreAllZero: Bool {
        let used = monthlyUsed ?? 0
        let limit = monthlyLimit ?? 0
        let historyZero = history.allSatisfy { $0.totalUsed == 0 }
        return used == 0 && limit == 0 && historyZero
    }

    var showsHistoryChart: Bool {
        !monthlyFiguresAreAllZero && history.count >= 2 && history.contains { $0.totalUsed > 0 }
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
    /// Last good snapshot. `nil` reason means a refresh is in flight; a string is the failure we're keeping on screen.
    case stale(BillingUsage, String?)
    case failed(String)
    case needsLogin
}
