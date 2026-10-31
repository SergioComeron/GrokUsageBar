//
//  UsageAlertPolicy.swift
//  GrokUsageBar
//
//  Which usage alerts to deliver for one refresh. Each threshold fires at most
//  once per billing period; a jump (0 → 95) delivers only the highest newly
//  crossed threshold and marks the lower ones done so they don't arrive late.
//  The optional pace alert also fires once per period.
//

import Foundation

struct UsageAlert: Equatable {
    var identifier: String
    var title: String
    var body: String
}

enum UsageAlertPolicy {
    /// Options shown in Settings. 80 and 100 match the previous defaults.
    static let catalog: [Int] = [50, 80, 90, 100]
    static let defaultThresholds: Set<Int> = [80, 100]

    static func evaluate(
        percent: Double,
        pace: UsagePace?,
        periodKey: String,
        periodLabel: String,
        enabledThresholds: Set<Int>,
        paceAlertsEnabled: Bool,
        firedThresholds: Set<Int>,
        firedPace: Bool
    ) -> (alerts: [UsageAlert], firedThresholds: Set<Int>, firedPace: Bool) {
        let percent = min(max(percent, 0), 1000)
        var firedThresholds = firedThresholds
        var firedPace = firedPace
        var alerts: [UsageAlert] = []

        let crossed = enabledThresholds.filter { percent >= Double($0) }.sorted()
        if let highest = crossed.last, !firedThresholds.contains(highest) {
            let title = highest >= 100 ? "Grok usage exhausted" : "Grok usage high"
            alerts.append(
                UsageAlert(
                    identifier: "grok-usage-\(highest)-\(periodKey)",
                    title: title,
                    body: "You've used \(BillingUsage.formatPercent(percent)) of your \(periodLabel)."
                )
            )
        }
        for value in crossed {
            firedThresholds.insert(value)
        }

        if percent >= 100 {
            // The limit alert already covers this; don't also send a pace warning.
            firedPace = true
        } else if paceAlertsEnabled, !firedPace, let pace, pace.hitsBeforeReset {
            alerts.append(
                UsageAlert(
                    identifier: "grok-usage-pace-\(periodKey)",
                    title: "Grok usage pace",
                    body: pace.notificationBody()
                )
            )
            firedPace = true
        }

        return (alerts, firedThresholds, firedPace)
    }

    /// New period → nothing has fired. Same period → keep the stored set, and
    /// honour the pre-0.2.5 80/100 flags so an upgrade doesn't alert twice.
    static func normalizedFired(
        periodKey: String,
        storedPeriodKey: String?,
        storedThresholds: Set<Int>,
        storedPace: Bool,
        legacyWarn: Bool,
        legacyCritical: Bool
    ) -> (Set<Int>, Bool) {
        guard storedPeriodKey == periodKey else { return ([], false) }
        var fired = storedThresholds
        if fired.isEmpty {
            if legacyCritical {
                fired.insert(80)
                fired.insert(100)
            } else if legacyWarn {
                fired.insert(80)
            }
        }
        return (fired, storedPace)
    }
}
