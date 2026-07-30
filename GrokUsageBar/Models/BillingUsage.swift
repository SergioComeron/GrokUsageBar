//
//  BillingUsage.swift
//  GrokUsageBar
//
//  Shape aligned with the fields Grok Build's /usage surface uses
//  (creditUsagePercent, included/total, period, on-demand, …).
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
    /// Past cycles (and usually the current one last), oldest → newest.
    var history: [UsageHistoryPoint]
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
        history: [],
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

    /// Values for the sparkline, oldest → newest.
    var sparklineValues: [Double] {
        history.map(\.totalUsed)
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
