//
//  UsageNotifier.swift
//  GrokUsageBar
//
//  Local notifications when credit usage crosses a configured threshold, and
//  an optional pace alert when the projection hits 100% before the reset.
//  Each alert fires at most once per billing period.
//

import Foundation
import UserNotifications

enum UsageNotifier {
    private enum Keys {
        static let enabled = "notificationsEnabled"
        static let thresholds = "alertThresholds"
        static let paceEnabled = "paceAlertsEnabled"
        static let periodKey = "notifiedPeriodKey"
        static let firedThresholds = "notifiedFiredThresholds"
        static let firedPace = "notifiedFiredPace"
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

    /// Empty means the user turned every threshold off. Missing key → 80 and 100.
    static var enabledThresholds: Set<Int> {
        get {
            guard UserDefaults.standard.object(forKey: Keys.thresholds) != nil else {
                return UsageAlertPolicy.defaultThresholds
            }
            return decodeThresholds(UserDefaults.standard.string(forKey: Keys.thresholds))
        }
        set {
            UserDefaults.standard.set(encodeThresholds(newValue), forKey: Keys.thresholds)
        }
    }

    static var paceAlertsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.paceEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.paceEnabled) }
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
        let (seedThresholds, seedPace) = UsageAlertPolicy.normalizedFired(
            periodKey: periodKey,
            storedPeriodKey: UserDefaults.standard.string(forKey: Keys.periodKey),
            storedThresholds: decodeThresholds(UserDefaults.standard.string(forKey: Keys.firedThresholds)),
            storedPace: UserDefaults.standard.bool(forKey: Keys.firedPace),
            legacyWarn: UserDefaults.standard.bool(forKey: Keys.firedWarn),
            legacyCritical: UserDefaults.standard.bool(forKey: Keys.firedCritical)
        )
        let decision = UsageAlertPolicy.evaluate(
            percent: usage.creditUsagePercent,
            pace: usage.pace(),
            periodKey: periodKey,
            periodLabel: usage.periodKind.titleLabel.lowercased(),
            enabledThresholds: enabledThresholds,
            paceAlertsEnabled: paceAlertsEnabled,
            firedThresholds: seedThresholds,
            firedPace: seedPace
        )

        UserDefaults.standard.set(periodKey, forKey: Keys.periodKey)
        UserDefaults.standard.set(encodeThresholds(decision.firedThresholds), forKey: Keys.firedThresholds)
        UserDefaults.standard.set(decision.firedPace, forKey: Keys.firedPace)
        UserDefaults.standard.set(false, forKey: Keys.firedWarn)
        UserDefaults.standard.set(false, forKey: Keys.firedCritical)

        for alert in decision.alerts {
            await post(id: alert.identifier, title: alert.title, body: alert.body)
        }
    }

    // MARK: - Private

    static func periodIdentity(_ usage: BillingUsage) -> String {
        if let start = usage.billingPeriodStart {
            return ISO8601DateFormatter.string(
                from: start,
                timeZone: TimeZone(secondsFromGMT: 0)!,
                formatOptions: [.withInternetDateTime]
            )
        }
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }

    private static func encodeThresholds(_ values: Set<Int>) -> String {
        values.sorted().map(String.init).joined(separator: ",")
    }

    private static func decodeThresholds(_ raw: String?) -> Set<Int> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { Int($0) })
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
