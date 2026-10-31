import XCTest
@testable import GrokUsageBarCore

final class UsageLogicTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func testUserAgentUsesBundleVersion() {
        XCTAssertEqual(GrokHTTP.userAgent(marketingVersion: "0.2.4"), "GrokUsageBar/0.2.4")
        XCTAssertEqual(GrokHTTP.userAgent(marketingVersion: " 1.0 "), "GrokUsageBar/1.0")
        XCTAssertEqual(GrokHTTP.userAgent(marketingVersion: nil), "GrokUsageBar/dev")
        XCTAssertEqual(GrokHTTP.userAgent(marketingVersion: "  "), "GrokUsageBar/dev")
    }

    func testJWTTierDecodedOncePerRead() {
        let session = makeSession(token: jwt(["tier": 5]), expiresAt: Date().addingTimeInterval(3600))
        XCTAssertEqual(session.jwtSubscriptionTier, 5)

        let numericString = makeSession(token: jwt(["tier": "2"]), expiresAt: Date().addingTimeInterval(3600))
        XCTAssertEqual(numericString.jwtSubscriptionTier, 2)
        XCTAssertNil(makeSession(token: "not-a-jwt", expiresAt: nil).jwtSubscriptionTier)
    }

    func testTierTwoMappingStaysHeavyAndIsSeparateFromTierFive() {
        XCTAssertEqual(GrokSubscriptionPlan.resolve(jwtTier: 2)?.displayName, "SuperGrok Heavy")
        XCTAssertEqual(GrokSubscriptionPlan.resolve(jwtTier: 5)?.displayName, "SuperGrok Heavy")
        XCTAssertEqual(GrokSubscriptionPlan.resolve(jwtTier: 1)?.displayName, "SuperGrok")
    }

    func testMissingCreditUsagePercentIsAnError() {
        let renamed = Data(#"{"config":{"currentPeriod":{"type":"WEEKLY","start":"2026-10-01T00:00:00Z","end":"2026-10-08T00:00:00Z"},"credit_usage_percent":40}}"#.utf8)
        XCTAssertThrowsError(try LiveBillingService.decode(credits: renamed, monthly: nil)) { error in
            XCTAssertEqual(error as? BillingServiceError, .missingCreditUsagePercent)
        }
    }

    func testExplicitZeroPercentIsKept() throws {
        let payload = Data(#"{"config":{"creditUsagePercent":0,"currentPeriod":{"type":"WEEKLY"}}}"#.utf8)
        let usage = try LiveBillingService.decode(credits: payload, monthly: nil)
        XCTAssertEqual(usage.creditUsagePercent, 0)
        XCTAssertEqual(usage.periodKind, .weekly)
    }

    func testLegacyMonthlyPayloadStillDecodes() throws {
        let payload = Data(#"{"config":{"monthlyLimit":{"val":100},"used":{"val":25},"billingPeriodStart":"2026-10-01T00:00:00Z","billingPeriodEnd":"2026-11-01T00:00:00Z"}}"#.utf8)
        let usage = try LiveBillingService.decode(credits: payload, monthly: nil)
        XCTAssertEqual(usage.creditUsagePercent, 25, accuracy: 0.001)
        XCTAssertEqual(usage.periodKind, .monthly)
        XCTAssertEqual(usage.monthlyLimit, 100)
    }

    func testAllZeroMonthlyIsHiddenButARealLimitIsNot() {
        var zeros = makeUsage(percent: 10)
        zeros.monthlyUsed = 0
        zeros.monthlyLimit = 0
        zeros.history = [
            UsageHistoryPoint(year: 2026, month: 9, totalUsed: 0, isCurrent: false),
            UsageHistoryPoint(year: 2026, month: 10, totalUsed: 0, isCurrent: true),
        ]
        XCTAssertTrue(zeros.monthlyFiguresAreAllZero)
        XCTAssertFalse(zeros.showsHistoryChart)

        var real = zeros
        real.monthlyLimit = 15_000
        real.monthlyUsed = 0
        XCTAssertFalse(real.monthlyFiguresAreAllZero)
        XCTAssertFalse(real.showsHistoryChart)

        real.history[0].totalUsed = 40
        XCTAssertTrue(real.showsHistoryChart)
    }

    func testPaceAheadOfScheduleNamesTheWeekday() {
        let start = Date(timeIntervalSince1970: 0) // Thursday
        let end = Date(timeIntervalSince1970: 7 * 86_400)
        let now = Date(timeIntervalSince1970: 86_400) // Friday
        let pace = UsagePace.evaluate(actualPercent: 50, periodStart: start, periodEnd: end, now: now)
        XCTAssertNotNil(pace)
        XCTAssertEqual(pace?.expectedPercent ?? -1, 100.0 / 7.0, accuracy: 0.001)
        XCTAssertEqual(pace?.hitsBeforeReset, true)
        XCTAssertEqual(
            pace?.projectionSentence(calendar: utc),
            "At this pace you hit 100% on Saturday."
        )
        XCTAssertEqual(pace?.comparisonSentence, "50% used · 14% expected")
        XCTAssertTrue(pace?.notificationBody(calendar: utc).contains("before the reset.") == true)
    }

    func testPaceBehindScheduleStaysUnderTheLimit() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 7 * 86_400)
        let now = Date(timeIntervalSince1970: 3.5 * 86_400)
        let pace = UsagePace.evaluate(actualPercent: 25, periodStart: start, periodEnd: end, now: now)!
        XCTAssertEqual(pace.expectedPercent, 50, accuracy: 0.001)
        XCTAssertFalse(pace.hitsBeforeReset)
        XCTAssertEqual(pace.projectedPercentAtReset ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(pace.projectionSentence(calendar: utc), "At this pace you finish near 50%.")
    }

    func testPaceEdges() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 7 * 86_400)
        let early = UsagePace.evaluate(
            actualPercent: 1,
            periodStart: start,
            periodEnd: end,
            now: start.addingTimeInterval(30)
        )!
        XCTAssertFalse(early.hasEnoughData)
        XCTAssertEqual(early.projectionSentence(calendar: utc), "Too early in the window to project pace.")

        let none = UsagePace.evaluate(
            actualPercent: 0,
            periodStart: start,
            periodEnd: end,
            now: start.addingTimeInterval(3 * 86_400)
        )!
        XCTAssertEqual(none.projectionSentence(calendar: utc), "No usage yet this window.")

        let done = UsagePace.evaluate(
            actualPercent: 100,
            periodStart: start,
            periodEnd: end,
            now: start.addingTimeInterval(86_400)
        )!
        XCTAssertTrue(done.alreadyAtLimit)
        XCTAssertFalse(done.hitsBeforeReset)
        XCTAssertEqual(done.projectionSentence(calendar: utc), "You've already hit 100% this window.")

        let over = UsagePace.evaluate(actualPercent: 40, periodStart: start, periodEnd: end, now: end.addingTimeInterval(60))!
        XCTAssertTrue(over.windowHasEnded)
        XCTAssertEqual(over.projectionSentence(calendar: utc), "This window has ended.")

        XCTAssertNil(UsagePace.evaluate(actualPercent: 10, periodStart: end, periodEnd: start, now: start))
    }

    func testAlertsFireHighestNewThresholdOncePerPeriod() {
        let pace = UsagePace.evaluate(
            actualPercent: 96,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 7 * 86_400),
            now: Date(timeIntervalSince1970: 86_400)
        )
        let first = UsageAlertPolicy.evaluate(
            percent: 96,
            pace: pace,
            periodKey: "week-1",
            periodLabel: "weekly limit",
            enabledThresholds: [50, 80, 90, 100],
            paceAlertsEnabled: true,
            firedThresholds: [],
            firedPace: false
        )
        XCTAssertEqual(first.alerts.map(\.identifier), ["grok-usage-90-week-1", "grok-usage-pace-week-1"])
        XCTAssertTrue(first.firedThresholds.contains(50))
        XCTAssertTrue(first.firedThresholds.contains(90))
        XCTAssertFalse(first.firedThresholds.contains(100))
        XCTAssertTrue(first.firedPace)

        let second = UsageAlertPolicy.evaluate(
            percent: 97,
            pace: pace,
            periodKey: "week-1",
            periodLabel: "weekly limit",
            enabledThresholds: [50, 80, 90, 100],
            paceAlertsEnabled: true,
            firedThresholds: first.firedThresholds,
            firedPace: first.firedPace
        )
        XCTAssertTrue(second.alerts.isEmpty)

        let critical = UsageAlertPolicy.evaluate(
            percent: 100,
            pace: pace,
            periodKey: "week-1",
            periodLabel: "weekly limit",
            enabledThresholds: [80, 100],
            paceAlertsEnabled: true,
            firedThresholds: second.firedThresholds,
            firedPace: second.firedPace
        )
        XCTAssertEqual(critical.alerts.map(\.title), ["Grok usage exhausted"])
        XCTAssertTrue(critical.firedPace)
    }

    func testAlertsResetWhenThePeriodChangesAndKeepLegacyFlags() {
        let fresh = UsageAlertPolicy.normalizedFired(
            periodKey: "week-2",
            storedPeriodKey: "week-1",
            storedThresholds: [80, 100],
            storedPace: true,
            legacyWarn: true,
            legacyCritical: true
        )
        XCTAssertTrue(fresh.0.isEmpty)
        XCTAssertFalse(fresh.1)

        let legacy = UsageAlertPolicy.normalizedFired(
            periodKey: "week-1",
            storedPeriodKey: "week-1",
            storedThresholds: [],
            storedPace: false,
            legacyWarn: true,
            legacyCritical: false
        )
        XCTAssertEqual(legacy.0, [80])

        let defaults = UsageAlertPolicy.defaultThresholds
        XCTAssertEqual(defaults, [80, 100])
        XCTAssertEqual(UsageAlertPolicy.catalog, [50, 80, 90, 100])
    }

    func testRefreshPlanAdoptsASiblingToken() {
        let fresh = makeSession(token: "new-access", expiresAt: Date().addingTimeInterval(10_000))
        let plan = GrokAuthStore.refreshPlan(
            disk: fresh,
            forceRefresh: true,
            rejectedAccessToken: "old-access"
        )
        guard case .adopt(let session) = plan else {
            return XCTFail("expected adopt, got \(plan)")
        }
        XCTAssertEqual(session.accessToken, "new-access")

        let same = GrokAuthStore.refreshPlan(
            disk: fresh,
            forceRefresh: true,
            rejectedAccessToken: "new-access"
        )
        guard case .performRefresh = same else {
            return XCTFail("expected refresh of the rejected token, got \(same)")
        }

        let expired = makeSession(token: "old", expiresAt: Date().addingTimeInterval(-10))
        guard case .performRefresh = GrokAuthStore.refreshPlan(disk: expired) else {
            return XCTFail("expected refresh")
        }
        var noRefresh = expired
        noRefresh.refreshToken = nil
        guard case .cannotRefresh = GrokAuthStore.refreshPlan(disk: noRefresh) else {
            return XCTFail("expected cannotRefresh")
        }
    }

    func testCoalescedRefreshDoesNotOverlap() async {
        let gate = RefreshCoalescer()
        let probe = ConcurrencyProbe()
        await withTaskGroup(of: Void.self) { group in
            for delay in [0, 10, 20, 30, 40] {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    await gate.run {
                        await probe.enter()
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        await probe.leave()
                    }
                }
            }
            await group.waitForAll()
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maxConcurrent, 1)
        XCTAssertGreaterThanOrEqual(snapshot.runs, 2)
        XCTAssertLessThanOrEqual(snapshot.runs, 5)
    }

    private func jwt(_ payload: [String: Any]) -> String {
        func b64(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "none"])).\(b64(payload)).sig"
    }

    private func makeSession(token: String, expiresAt: Date?) -> GrokSession {
        GrokSession(
            entryKey: "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: expiresAt,
            email: nil,
            userId: nil,
            teamId: nil,
            oidcIssuer: "https://auth.x.ai",
            oidcClientId: "b1a00492-073a-47ea-816f-4c329264a828",
            authMode: "oidc",
            givenName: nil,
            familyName: nil
        )
    }

    private func makeUsage(percent: Double) -> BillingUsage {
        BillingUsage(
            creditUsagePercent: percent,
            periodKind: .weekly,
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
            fetchedAt: Date()
        )
    }
}

private actor ConcurrencyProbe {
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var runs = 0

    func enter() {
        current += 1
        runs += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func leave() {
        current -= 1
    }

    func snapshot() -> (maxConcurrent: Int, runs: Int) {
        (maxConcurrent, runs)
    }
}
