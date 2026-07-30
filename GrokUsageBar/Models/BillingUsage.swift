//
//  BillingUsage.swift
//  GrokUsageBar
//
//  Shape aligned with the fields Grok Build's /usage surface uses
//  (creditUsagePercent, included/total, period, on-demand, …).
//

import Foundation

/// Snapshot of account credit usage for the current billing period.
struct BillingUsage: Equatable, Sendable {
    /// 0…100 — same idea as `creditUsagePercent` in Grok Build.
    var creditUsagePercent: Double
    var includedUsed: Double?
    var totalUsed: Double?
    var monthlyLimit: Double?
    var prepaidBalance: Double?
    var onDemandCap: Double?
    var onDemandUsed: Double?
    var billingPeriodStart: Date?
    var billingPeriodEnd: Date?
    var isUnifiedBillingUser: Bool?
    /// When this snapshot was fetched locally.
    var fetchedAt: Date

    static let placeholder = BillingUsage(
        creditUsagePercent: 0,
        includedUsed: nil,
        totalUsed: nil,
        monthlyLimit: nil,
        prepaidBalance: nil,
        onDemandCap: nil,
        onDemandUsed: nil,
        billingPeriodStart: nil,
        billingPeriodEnd: nil,
        isUnifiedBillingUser: nil,
        fetchedAt: .distantPast
    )

    /// Compact label for the menu bar and panel.
    /// Under 10% keeps one decimal so low burn rates stay visible (e.g. 0.7%).
    var percentDisplay: String {
        let value = creditUsagePercent.clamped(to: 0...100)
        if value >= 10 || value == 0 {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.1f%%", value)
    }

    var usageLevel: UsageLevel {
        switch creditUsagePercent {
        case ..<50: return .ok
        case ..<80: return .warn
        default: return .high
        }
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
