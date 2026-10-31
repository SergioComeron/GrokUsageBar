//
//  UsagePace.swift
//  GrokUsageBar
//
//  Expected-vs-actual burn inside the account's weekly window, plus a
//  projection of when the current rate would reach 100%.
//

import Foundation

struct UsagePace: Equatable {
    var actualPercent: Double
    var expectedPercent: Double
    /// Usage percent at the window end if the rate since `periodStart` holds.
    var projectedPercentAtReset: Double?
    /// When the current rate reaches 100%. Nil when there is nothing to project.
    var projectedLimitDate: Date?
    var hitsBeforeReset: Bool
    var alreadyAtLimit: Bool
    var hasEnoughData: Bool
    var windowHasEnded: Bool
    var evaluatedAt: Date

    /// "46% used · 30% expected"
    var comparisonSentence: String {
        let actual = BillingUsage.formatPercent(actualPercent)
        let expected = BillingUsage.formatPercent(expectedPercent)
        return "\(actual) used · \(expected) expected"
    }

    /// English, matching the rest of the menu copy. The weekday is the user's
    /// local day; the word itself stays English so it agrees with the sentence.
    func projectionSentence(calendar: Calendar = .current) -> String {
        if windowHasEnded {
            if alreadyAtLimit {
                return "You've already hit 100% this window."
            }
            return "This window has ended."
        }
        if alreadyAtLimit {
            return "You've already hit 100% this window."
        }
        if !hasEnoughData {
            return "Too early in the window to project pace."
        }
        if actualPercent <= 0 {
            return "No usage yet this window."
        }
        if hitsBeforeReset, let date = projectedLimitDate {
            if calendar.isDate(date, inSameDayAs: evaluatedAt) {
                return "At this pace you hit 100% today."
            }
            let name = Self.englishWeekday(date, calendar: calendar)
            return "At this pace you hit 100% on \(name)."
        }
        if let projected = projectedPercentAtReset {
            return "At this pace you finish near \(BillingUsage.formatPercent(projected))."
        }
        return "At this pace you stay under the limit."
    }

    /// Same projection, phrased as a notification body.
    func notificationBody(calendar: Calendar = .current) -> String {
        let sentence = projectionSentence(calendar: calendar)
        guard hitsBeforeReset else { return sentence }
        if sentence.hasSuffix(".") {
            return String(sentence.dropLast()) + ", before the reset."
        }
        return sentence + ", before the reset."
    }

    static func evaluate(
        actualPercent: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date,
        minimumElapsed: TimeInterval = 15 * 60,
        earlyUsagePercent: Double = 10
    ) -> UsagePace? {
        let duration = periodEnd.timeIntervalSince(periodStart)
        guard duration > 0 else { return nil }

        let elapsed = now.timeIntervalSince(periodStart)
        let windowHasEnded = now >= periodEnd
        let clampedElapsed = min(max(elapsed, 0), duration)
        let expected = (clampedElapsed / duration) * 100
        let already = actualPercent >= 100
        let hasEnoughData = !windowHasEnded && (
            elapsed >= minimumElapsed || (actualPercent >= earlyUsagePercent && elapsed >= 1)
        )

        var projectedAtReset: Double?
        var projectedDate: Date?
        var hitsBefore = false

        // Need a measurable elapsed slice so a tiny denominator doesn't
        // project "100% in the next second" off a rounding error.
        if elapsed > 1, actualPercent > 0, !already {
            let rate = actualPercent / elapsed
            let remaining = max(periodEnd.timeIntervalSince(now), 0)
            projectedAtReset = actualPercent + rate * remaining
            let secondsToLimit = (100 - actualPercent) / rate
            if secondsToLimit.isFinite, secondsToLimit >= 0 {
                let date = now.addingTimeInterval(secondsToLimit)
                projectedDate = date
                if hasEnoughData {
                    hitsBefore = date < periodEnd
                }
            }
        }

        return UsagePace(
            actualPercent: actualPercent,
            expectedPercent: expected,
            projectedPercentAtReset: projectedAtReset,
            projectedLimitDate: projectedDate,
            hitsBeforeReset: hitsBefore && !windowHasEnded,
            alreadyAtLimit: already,
            hasEnoughData: hasEnoughData,
            windowHasEnded: windowHasEnded,
            evaluatedAt: now
        )
    }

    private static let englishWeekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    private static func englishWeekday(_ date: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        guard englishWeekdayNames.indices.contains(index) else { return "that day" }
        return englishWeekdayNames[index]
    }
}
