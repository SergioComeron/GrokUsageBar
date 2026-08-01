//
//  BillingService.swift
//  GrokUsageBar
//
//  Same sources Grok Build uses for /usage:
//
//  1) GET …/v1/billing?format=credits  → weekly creditUsagePercent (what counts)
//  2) GET …/v1/billing                 → monthly unit pool (secondary)
//
//  Authorization: Bearer <token from ~/.grok/auth.json>
//

import Foundation

protocol BillingServing: Sendable {
    func fetchUsage(session: GrokSession) async throws -> BillingUsage
}

enum BillingServiceError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case badResponse(Int)
    case decodeFailed
    case transport(String)

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
        case .transport(let message):
            return message
        }
    }
}

// MARK: - Live (default)

/// Real billing client matching Grok Build's /usage data source.
struct LiveBillingService: BillingServing {
    /// Weekly limit + product breakdown (primary).
    static let creditsEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    /// Monthly unit pool (secondary).
    static let monthlyEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    /// Override for tests / env (`GROK_BILLING_ENDPOINT` still supported as credits URL).
    var creditsURL: URL = creditsEndpoint
    var monthlyURL: URL = monthlyEndpoint
    var urlSession: URLSession = .shared

    func fetchUsage(session: GrokSession) async throws -> BillingUsage {
        // Weekly is required; monthly is best-effort in parallel.
        async let creditsData = fetchData(from: creditsURL, session: session)
        async let monthlyData = optionalFetchData(from: monthlyURL, session: session)

        let credits = try await creditsData
        let monthly = await monthlyData

        var usage = try Self.decode(credits: credits, monthly: monthly)
        // Plan name: prefer API fields if present, else JWT `tier` claim.
        if usage.subscription == nil {
            usage.subscription = GrokSubscriptionPlan.resolve(jwtTier: session.jwtSubscriptionTier)
        } else if usage.subscription?.rawTier == nil, let t = session.jwtSubscriptionTier {
            usage.subscription = GrokSubscriptionPlan.resolve(
                jwtTier: t,
                apiDisplayName: usage.subscription?.displayName
            )
        }
        return usage
    }

    private func fetchData(from url: URL, session: GrokSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("GrokUsageBar/0.2", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

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
        let percent = config.creditUsagePercent ?? 0
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
}

// MARK: - Remote JSON (format=credits)

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
