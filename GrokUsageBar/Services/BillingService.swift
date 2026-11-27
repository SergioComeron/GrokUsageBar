//
//  BillingService.swift
//  GrokUsageBar
//
//  Same sources Grok Build uses for /usage, plus grok.com for the plan name:
//
//  1) GET …/v1/billing?format=credits  → weekly creditUsagePercent (what counts)
//  2) GET …/v1/billing                 → monthly unit pool (secondary)
//  3) GET https://grok.com/rest/subscriptions → The X Subscription plan
//     (best-effort; Ultra still reports as SuperGrok Heavy elsewhere)
//
//  Authorization: Bearer <token from ~/.grok/auth.json>
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol BillingServing: Sendable {
    func fetchUsage(session: GrokSession) async throws -> BillingUsage
}

enum BillingServiceError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case badResponse(Int)
    case decodeFailed
    case missingCreditUsagePercent
    case transport(String)
    case rateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Billing endpoint is not configured."
        case .unauthorized:
            return "Billing API rejected the session (401). Try `grok login`."
        case .badResponse(let code):
            return "Billing API returned HTTP \(code)."
        case .decodeFailed:
            return "Could not parse billing response."
        case .missingCreditUsagePercent:
            return "Billing response did not include creditUsagePercent."
        case .transport(let message):
            return message
        case .rateLimited(let retryAfter):
            return RateLimitBackoff.errorDescription(retryAfter: retryAfter)
        }
    }
}

/// How long to pause after HTTP 429. Honours `Retry-After` in seconds, with a
/// 5-minute default and a 15-minute cap so the bar is not stuck all day.
enum RateLimitBackoff {
    static let defaultDelay: TimeInterval = 5 * 60
    static let maximumDelay: TimeInterval = 15 * 60

    /// Parsed delay from an HTTP 429. Nil when the status is not 429.
    static func delay(statusCode: Int, retryAfterHeader: String?) -> TimeInterval? {
        guard statusCode == 429 else { return nil }
        return clamp(parseRetryAfter(retryAfterHeader) ?? defaultDelay)
    }

    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds.isFinite, seconds > 0 {
            return seconds
        }
        return nil
    }

    static func clamp(_ delay: TimeInterval) -> TimeInterval {
        min(maximumDelay, max(1, delay))
    }

    static func until(retryAfter: TimeInterval, now: Date = Date()) -> Date {
        now.addingTimeInterval(clamp(retryAfter))
    }

    static func shouldSkip(until: Date?, now: Date = Date()) -> Bool {
        guard let until else { return false }
        return now < until
    }

    static func message(until: Date, now: Date = Date()) -> String {
        formatWait("Rate limited. Retrying", remaining: until.timeIntervalSince(now))
    }

    static func errorDescription(retryAfter: TimeInterval) -> String {
        formatWait("Billing API rate limited (HTTP 429). Retrying", remaining: clamp(retryAfter))
    }

    private static func formatWait(_ prefix: String, remaining: TimeInterval) -> String {
        if remaining <= 0 {
            return "\(prefix)…"
        }
        if remaining < 90 {
            let seconds = max(1, Int(remaining.rounded()))
            return "\(prefix) in \(seconds)s."
        }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return "\(prefix) in \(minutes) min."
    }
}

// MARK: - Live (default)

/// Real billing client matching Grok Build's /usage data source.
struct LiveBillingService: BillingServing {
    /// Weekly limit + product breakdown (primary).
    static let creditsEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    /// Monthly unit pool (secondary).
    static let monthlyEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    /// Active subscriptions as grok.com's billing page sees them (plan name).
    static let subscriptionsEndpoint = URL(string: "https://grok.com/rest/subscriptions")!

    /// Override for tests / env (`GROK_BILLING_ENDPOINT` still supported as credits URL).
    var creditsURL: URL = creditsEndpoint
    var monthlyURL: URL = monthlyEndpoint
    var subscriptionsURL: URL = subscriptionsEndpoint
    var urlSession: URLSession = .shared

    func fetchUsage(session: GrokSession) async throws -> BillingUsage {
        // Weekly is required; monthly and the subscriptions list are best-effort.
        async let creditsData = fetchData(from: creditsURL, session: session)
        async let monthlyData = optionalFetchData(from: monthlyURL, session: session)
        async let subscriptionsData = optionalFetchData(from: subscriptionsURL, session: session)

        let credits = try await creditsData
        let monthly = await monthlyData
        let subscriptions = await subscriptionsData

        var usage = try Self.decode(credits: credits, monthly: monthly)
        // Plan name: The X Subscription list first (Ultra still looks like
        // Heavy in the JWT and in settings), then billing/settings display
        // fields, then JWT `tier`. Decode the JWT once; the claim is display-only.
        let jwtTier = session.jwtSubscriptionTier
        let commerce = subscriptions.flatMap { Self.parseActiveSubscription($0) }
        usage.subscription = GrokSubscriptionPlan.resolve(
            jwtTier: jwtTier,
            apiDisplayName: usage.subscription?.displayName,
            commerceTier: commerce?.tier,
            commerceBillingSystem: commerce?.billingSystem
        )
        return usage
    }

    private func fetchData(from url: URL, session: GrokSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(GrokHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        // grok.com/rest/subscriptions is a first-party web endpoint; send the
        // same Origin/Referer the site uses and skip cookies (bearer is enough).
        if url.host?.caseInsensitiveCompare("grok.com") == .orderedSame {
            request.httpShouldHandleCookies = false
            request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            request.setValue("https://grok.com/", forHTTPHeaderField: "Referer")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw BillingServiceError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BillingServiceError.badResponse(-1)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw BillingServiceError.unauthorized
        }
        if http.statusCode == 429 {
            let header = http.value(forHTTPHeaderField: "Retry-After")
            let delay = RateLimitBackoff.delay(statusCode: 429, retryAfterHeader: header)
                ?? RateLimitBackoff.defaultDelay
            throw BillingServiceError.rateLimited(retryAfter: delay)
        }
        guard (200...299).contains(http.statusCode) else {
            throw BillingServiceError.badResponse(http.statusCode)
        }
        return data
    }

    private func optionalFetchData(from url: URL, session: GrokSession) async -> Data? {
        try? await fetchData(from: url, session: session)
    }

    // MARK: - Decode

    /// Primary payload from `?format=credits` (weekly). Optional monthly units from plain `/billing`.
    static func decode(credits: Data, monthly: Data?) throws -> BillingUsage {
        let root: RemoteCreditsRoot
        do {
            root = try JSONDecoder().decode(RemoteCreditsRoot.self, from: credits)
        } catch {
            // Fallback: maybe the caller only has the legacy monthly shape.
            if let monthlyOnly = try? decodeLegacyMonthlyOnly(credits) {
                return monthlyOnly
            }
            throw BillingServiceError.decodeFailed
        }

        let config = root.config
        // Explicit 0 is fine. A renamed field (e.g. credit_usage_percent) must
        // still error, even when productUsage is present, so we don't paint 0%.
        // After a weekly reset the API may omit creditUsagePercent and
        // productUsage instead of sending 0; treat that as 0%.
        // Legacy monthly payloads (used / monthlyLimit, no credit fields) still decode below.
        let percent: Double
        if let value = config.creditUsagePercent {
            percent = value
        } else if Self.hasRenamedCreditUsageField(credits) {
            throw BillingServiceError.missingCreditUsagePercent
        } else if config.currentPeriod != nil, (config.productUsage ?? []).isEmpty {
            percent = 0
        } else if Self.isLegacyMonthlyPayload(credits),
                  let monthlyOnly = try? decodeLegacyMonthlyOnly(credits) {
            return monthlyOnly
        } else {
            throw BillingServiceError.missingCreditUsagePercent
        }
        let periodKind = UsagePeriodKind.parse(config.currentPeriod?.type)
            ?? (config.currentPeriod != nil ? .weekly : .unknown)

        let periodStart = (config.currentPeriod?.start ?? config.billingPeriodStart)
            .flatMap(Self.parseDate)
        let periodEnd = (config.currentPeriod?.end ?? config.billingPeriodEnd)
            .flatMap(Self.parseDate)

        let products = (config.productUsage ?? []).map {
            ProductUsageShare(product: $0.product ?? "?", usagePercent: $0.usagePercent ?? 0)
        }

        var monthlyUsed: Double?
        var monthlyLimit: Double?
        var history: [UsageHistoryPoint] = []
        if let monthly, let monthlyRoot = try? JSONDecoder().decode(RemoteMonthlyRoot.self, from: monthly) {
            monthlyUsed = monthlyRoot.config.used?.val
            monthlyLimit = monthlyRoot.config.monthlyLimit?.val
            history = buildHistory(
                remote: monthlyRoot.config.history ?? [],
                currentUsed: monthlyUsed ?? 0,
                periodStart: monthlyRoot.config.billingPeriodStart.flatMap(Self.parseDate)
            )
        }

        let subscription = GrokSubscriptionPlan.resolve(
            jwtTier: nil,
            apiDisplayName: config.subscriptionTierDisplay,
            apiTierKey: config.subscriptionTier
        )

        return BillingUsage(
            creditUsagePercent: percent,
            periodKind: periodKind,
            includedUsed: nil,
            totalUsed: monthlyUsed,
            monthlyLimit: monthlyLimit,
            monthlyUsed: monthlyUsed,
            prepaidBalance: config.prepaidBalance?.val,
            onDemandCap: config.onDemandCap?.val,
            onDemandUsed: config.onDemandUsed?.val,
            billingPeriodStart: periodStart,
            billingPeriodEnd: periodEnd,
            isUnifiedBillingUser: config.isUnifiedBillingUser,
            subscription: subscription,
            productUsage: products,
            history: history,
            fetchedAt: Date()
        )
    }

    /// True when the payload uses a snake_case (or otherwise renamed) percent
    /// field instead of `creditUsagePercent`. Those must not decode as 0%.
    private static func hasRenamedCreditUsageField(_ data: Data) -> Bool {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = obj["config"] as? [String: Any]
        else { return false }
        if config["creditUsagePercent"] != nil { return false }
        return config["credit_usage_percent"] != nil
    }

    /// True for the pre-credits monthly document. A credits document that simply
    /// dropped `creditUsagePercent` (it has `currentPeriod` / `productUsage`) is not legacy.
    private static func isLegacyMonthlyPayload(_ data: Data) -> Bool {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = obj["config"] as? [String: Any]
        else { return false }
        if config["creditUsagePercent"] != nil { return false }
        if config["currentPeriod"] != nil { return false }
        if config["productUsage"] != nil { return false }
        return config["monthlyLimit"] != nil || config["used"] != nil
    }

    /// Old shape: `{ config: { monthlyLimit, used, history, … } }` without creditUsagePercent.
    private static func decodeLegacyMonthlyOnly(_ data: Data) throws -> BillingUsage {
        let root = try JSONDecoder().decode(RemoteMonthlyRoot.self, from: data)
        let config = root.config
        let used = config.used?.val ?? 0
        let limit = config.monthlyLimit?.val ?? 0
        let percent: Double
        if limit > 0 {
            percent = (used / limit) * 100
        } else if used > 0 {
            percent = 100
        } else {
            percent = 0
        }
        let periodStart = config.billingPeriodStart.flatMap(Self.parseDate)
        let periodEnd = config.billingPeriodEnd.flatMap(Self.parseDate)
        return BillingUsage(
            creditUsagePercent: percent,
            periodKind: .monthly,
            includedUsed: used,
            totalUsed: used,
            monthlyLimit: limit > 0 ? limit : nil,
            monthlyUsed: used,
            prepaidBalance: nil,
            onDemandCap: config.onDemandCap?.val,
            onDemandUsed: nil,
            billingPeriodStart: periodStart,
            billingPeriodEnd: periodEnd,
            isUnifiedBillingUser: nil,
            subscription: nil,
            productUsage: [],
            history: buildHistory(
                remote: config.history ?? [],
                currentUsed: used,
                periodStart: periodStart
            ),
            fetchedAt: Date()
        )
    }

    /// Past cycles (API is newest-first) plus the current period, oldest → newest.
    private static func buildHistory(
        remote: [RemoteBillingHistory],
        currentUsed: Double,
        periodStart: Date?
    ) -> [UsageHistoryPoint] {
        var points: [UsageHistoryPoint] = remote.compactMap { row in
            guard let year = row.billingCycle?.year, let month = row.billingCycle?.month else {
                return nil
            }
            return UsageHistoryPoint(
                year: year,
                month: month,
                totalUsed: row.totalUsed?.val ?? row.includedUsed?.val ?? 0,
                isCurrent: false
            )
        }
        points.sort { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            return lhs.month < rhs.month
        }

        if let periodStart {
            let cal = Calendar(identifier: .gregorian)
            let year = cal.component(.year, from: periodStart)
            let month = cal.component(.month, from: periodStart)
            points.removeAll { $0.year == year && $0.month == month }
            points.append(
                UsageHistoryPoint(
                    year: year,
                    month: month,
                    totalUsed: currentUsed,
                    isCurrent: true
                )
            )
        }

        return points
    }

    private static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.grokFractional.date(from: raw)
            ?? ISO8601DateFormatter.grok.date(from: raw)
    }

    // MARK: - grok.com subscriptions

    struct ActiveSubscription: Equatable, Sendable {
        var tier: String?
        var billingSystem: String?
    }

    /// Newest `SUBSCRIPTION_STATUS_ACTIVE` row. An account can have more than
    /// one active row during a switch (for example a leftover X Premium
    /// alongside the new commerce plan); `createTime` picks the one just bought.
    static func parseActiveSubscription(_ data: Data) -> ActiveSubscription? {
        guard let root = try? JSONDecoder().decode(RemoteSubscriptionsRoot.self, from: data) else {
            return nil
        }
        let active = (root.subscriptions ?? [])
            .filter { $0.status == "SUBSCRIPTION_STATUS_ACTIVE" }
            .sorted { ($0.createTime ?? "") > ($1.createTime ?? "") }
            .first
        guard let active else { return nil }
        return ActiveSubscription(tier: active.tier, billingSystem: active.billingSystem)
    }
}

// MARK: - Remote JSON (format=credits)

private struct RemoteSubscriptionsRoot: Decodable {
    let subscriptions: [RemoteSubscription]?
}

private struct RemoteSubscription: Decodable {
    let tier: String?
    let status: String?
    let billingSystem: String?
    let createTime: String?
}

private struct RemoteCreditsRoot: Decodable {
    let config: RemoteCreditsConfig
}

private struct RemoteCreditsConfig: Decodable {
    let currentPeriod: RemoteCurrentPeriod?
    let creditUsagePercent: Double?
    let onDemandCap: RemoteVal?
    let onDemandUsed: RemoteVal?
    let productUsage: [RemoteProductUsage]?
    let isUnifiedBillingUser: Bool?
    let prepaidBalance: RemoteVal?
    let billingPeriodStart: String?
    let billingPeriodEnd: String?
    /// Present on some billing payloads / future API versions.
    let subscriptionTier: String?
    let subscriptionTierDisplay: String?
}

private struct RemoteCurrentPeriod: Decodable {
    let type: String?
    let start: String?
    let end: String?
}

private struct RemoteProductUsage: Decodable {
    let product: String?
    let usagePercent: Double?
}

// MARK: - Remote JSON (plain monthly)

private struct RemoteMonthlyRoot: Decodable {
    let config: RemoteMonthlyConfig
}

private struct RemoteMonthlyConfig: Decodable {
    let monthlyLimit: RemoteVal?
    let used: RemoteVal?
    let onDemandCap: RemoteVal?
    let billingPeriodStart: String?
    let billingPeriodEnd: String?
    let history: [RemoteBillingHistory]?
}

private struct RemoteBillingHistory: Decodable {
    let billingCycle: RemoteBillingCycle?
    let includedUsed: RemoteVal?
    let onDemandUsed: RemoteVal?
    let totalUsed: RemoteVal?
}

private struct RemoteBillingCycle: Decodable {
    let year: Int?
    let month: Int?
}

/// Many money fields arrive as `{ "val": <number> }`.
private struct RemoteVal: Decodable {
    let val: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let d = try? container.decode(Double.self, forKey: .val) {
            val = d
            return
        }
        if let i = try? container.decode(Int.self, forKey: .val) {
            val = Double(i)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .val,
            in: container,
            debugDescription: "Expected numeric val"
        )
    }

    private enum CodingKeys: String, CodingKey { case val }
}

private extension UsagePeriodKind {
    static func parse(_ raw: String?) -> UsagePeriodKind? {
        guard let raw else { return nil }
        let upper = raw.uppercased()
        if upper.contains("WEEKLY") { return .weekly }
        if upper.contains("MONTHLY") { return .monthly }
        return nil
    }
}

private extension ISO8601DateFormatter {
    static let grok: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let grokFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Mock (previews / offline demos)

struct MockBillingService: BillingServing {
    var percent: Double = 46
    var delayNanoseconds: UInt64 = 200_000_000

    func fetchUsage(session: GrokSession) async throws -> BillingUsage {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let now = Date()
        let weekStart = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let weekEnd = Calendar.current.date(byAdding: .day, value: 4, to: now)!
        return BillingUsage(
            creditUsagePercent: percent,
            periodKind: .weekly,
            includedUsed: nil,
            totalUsed: 120,
            monthlyLimit: 15_000,
            monthlyUsed: 120,
            prepaidBalance: 0,
            onDemandCap: 0,
            onDemandUsed: 0,
            billingPeriodStart: weekStart,
            billingPeriodEnd: weekEnd,
            isUnifiedBillingUser: true,
            subscription: GrokSubscriptionPlan.resolve(jwtTier: 1),
            productUsage: [
                ProductUsageShare(product: "GrokBuild", usagePercent: percent * 0.9),
                ProductUsageShare(product: "GrokChat", usagePercent: percent * 0.05),
                ProductUsageShare(product: "GrokImagine", usagePercent: percent * 0.05),
            ],
            history: [],
            fetchedAt: now
        )
    }
}

// MARK: - Factory

enum BillingServiceFactory {
    /// Live by default. Force mock with env `GROK_USAGE_MOCK=1` or UserDefaults `useMockBilling`.
    static func make() -> any BillingServing {
        if ProcessInfo.processInfo.environment["GROK_USAGE_MOCK"] == "1"
            || UserDefaults.standard.bool(forKey: "useMockBilling") {
            return MockBillingService()
        }
        // Custom credits endpoint override (full URL, may include ?format=credits).
        if let raw = UserDefaults.standard.string(forKey: "billingEndpoint"),
           let url = URL(string: raw), !raw.isEmpty {
            return LiveBillingService(creditsURL: url)
        }
        if let raw = ProcessInfo.processInfo.environment["GROK_BILLING_ENDPOINT"],
           let url = URL(string: raw), !raw.isEmpty {
            return LiveBillingService(creditsURL: url)
        }
        return LiveBillingService()
    }
}
