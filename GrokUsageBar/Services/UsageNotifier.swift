//
//  UsageNotifier.swift
//  GrokUsageBar
//
//  Local notifications when credit usage crosses 80% and 100%.
//  Each threshold fires at most once per billing period (keyed by period start).
//

import Foundation
import UserNotifications

enum UsageNotifier {
    static let warnThreshold: Double = 80
    static let criticalThreshold: Double = 100

    private enum Keys {
        static let enabled = "notificationsEnabled"
        static let periodKey = "notifiedPeriodKey"
        static let firedWarn = "notifiedFiredWarn"
        static let firedCritical = "notifiedFiredCritical"
    }

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.enabled) == nil {
                return true // on by default; still needs OS permission
            }
            return UserDefaults.standard.bool(forKey: Keys.enabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// Ask the system for alert permission (no-op if already decided).
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Evaluate thresholds for a freshly loaded usage snapshot.
    static func evaluate(_ usage: BillingUsage) async {
        guard isEnabled else { return }

        let periodKey = periodIdentity(usage)
        resetIfPeriodChanged(periodKey)

        let percent = usage.creditUsagePercent.clamped(to: 0...1000) // allow slight overshoot
        var firedWarn = UserDefaults.standard.bool(forKey: Keys.firedWarn)
        var firedCritical = UserDefaults.standard.bool(forKey: Keys.firedCritical)

        if percent >= criticalThreshold, !firedCritical {
            await post(
                id: "grok-usage-critical-\(periodKey)",
                title: "Grok usage exhausted",
                body: "You've used \(usage.percentDisplay) of this period's credits."
            )
            firedCritical = true
            firedWarn = true
            UserDefaults.standard.set(true, forKey: Keys.firedCritical)
            UserDefaults.standard.set(true, forKey: Keys.firedWarn)
        } else if percent >= warnThreshold, !firedWarn {
            await post(
                id: "grok-usage-warn-\(periodKey)",
                title: "Grok usage high",
                body: "You've used \(usage.percentDisplay) of this period's credits."
            )
            firedWarn = true
            UserDefaults.standard.set(true, forKey: Keys.firedWarn)
        }
    }

    // MARK: - Private

    private static func periodIdentity(_ usage: BillingUsage) -> String {
        if let start = usage.billingPeriodStart {
            return ISO8601DateFormatter.string(from: start, timeZone: TimeZone(secondsFromGMT: 0)!, formatOptions: [.withInternetDateTime])
        }
        // Fall back to calendar month so a missing start still resets monthly.
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }

    private static func resetIfPeriodChanged(_ periodKey: String) {
        let previous = UserDefaults.standard.string(forKey: Keys.periodKey)
        guard previous != periodKey else { return }
        UserDefaults.standard.set(periodKey, forKey: Keys.periodKey)
        UserDefaults.standard.set(false, forKey: Keys.firedWarn)
        UserDefaults.standard.set(false, forKey: Keys.firedCritical)
    }

    private static func post(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // deliver immediately
        )
        try? await center.add(request)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
