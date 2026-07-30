//
//  BillingService.swift
//  GrokUsageBar
//
//  Same source Grok Build uses for /usage:
//  GET https://cli-chat-proxy.grok.com/v1/billing
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
    static let defaultEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    var endpoint: URL = defaultEndpoint
    var urlSession: URLSession = .shared

    func fetchUsage(session: GrokSession) async throws -> BillingUsage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("GrokUsageBar/0.1", forHTTPHeaderField: "User-Agent")
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

        return try Self.decode(data)
    }

    /// Parse the cli-chat-proxy billing payload.
    ///
    /// Example:
    /// ```json
    /// {
    ///   "config": {
    ///     "monthlyLimit": { "val": 15000 },
    ///     "used": { "val": 103 },
    ///     "onDemandCap": { "val": 0 },
    ///     "billingPeriodStart": "2026-07-01T00:00:00+00:00",
    ///     "billingPeriodEnd": "2026-08-01T00:00:00+00:00",
    ///     "history": [ ... ]
    ///   }
    /// }
    /// ```
    static func decode(_ data: Data) throws -> BillingUsage {
        let root: RemoteBillingRoot
        do {
            root = try JSONDecoder().decode(RemoteBillingRoot.self, from: data)
        } catch {
            throw BillingServiceError.decodeFailed
        }

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

        // Prefer current-period fields; fall back to newest history entry.
        let latestHistory = config.history?.first
        let includedUsed = latestHistory?.includedUsed?.val
        let onDemandUsed = latestHistory?.onDemandUsed?.val
        let totalUsed = config.used?.val ?? latestHistory?.totalUsed?.val
        let periodStart = config.billingPeriodStart.flatMap(Self.parseDate)
        let periodEnd = config.billingPeriodEnd.flatMap(Self.parseDate)

        return BillingUsage(
            creditUsagePercent: percent,
            includedUsed: includedUsed ?? totalUsed,
            totalUsed: totalUsed,
            monthlyLimit: limit > 0 ? limit : nil,
            prepaidBalance: nil,
            onDemandCap: config.onDemandCap?.val,
            onDemandUsed: onDemandUsed,
            billingPeriodStart: periodStart,
            billingPeriodEnd: periodEnd,
            isUnifiedBillingUser: nil,
            history: Self.buildHistory(
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
        // API lists newest first → chronological for the sparkline.
        points.sort { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            return lhs.month < rhs.month
        }

        if let periodStart {
            let cal = Calendar(identifier: .gregorian)
            let year = cal.component(.year, from: periodStart)
            let month = cal.component(.month, from: periodStart)
            // Drop a history row that already represents this month, then append current.
            points.removeAll { $0.year == year && $0.month == month }
            points.append(
                UsageHistoryPoint(
                    year: year,
                    month: month,
                    totalUsed: currentUsed,
                    isCurrent: true
                )
            )
        } else if !points.isEmpty {
            // No period start: treat the last (newest after sort) as current if needed.
        }

        return points
    }

    private static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.grokFractional.date(from: raw)
            ?? ISO8601DateFormatter.grok.date(from: raw)
    }
}

// MARK: - Remote JSON

private struct RemoteBillingRoot: Decodable {
    let config: RemoteBillingConfig
}

private struct RemoteBillingConfig: Decodable {
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
    var percent: Double = 37
    var delayNanoseconds: UInt64 = 200_000_000

    func fetchUsage(session: GrokSession) async throws -> BillingUsage {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let currentUsed = percent * 10
        var history: [UsageHistoryPoint] = []
        for offset in [3, 2, 1] {
            var comps = DateComponents()
            comps.year = year
            comps.month = month - offset
            if let date = cal.date(from: comps) {
                history.append(
                    UsageHistoryPoint(
                        year: cal.component(.year, from: date),
                        month: cal.component(.month, from: date),
                        totalUsed: Double([120, 450, 280][offset - 1]),
                        isCurrent: false
                    )
                )
            }
        }
        history.append(
            UsageHistoryPoint(year: year, month: month, totalUsed: currentUsed, isCurrent: true)
        )
        return BillingUsage(
            creditUsagePercent: percent,
            includedUsed: currentUsed,
            totalUsed: currentUsed,
            monthlyLimit: 1000,
            prepaidBalance: nil,
            onDemandCap: 0,
            onDemandUsed: 0,
            billingPeriodStart: Calendar.current.date(byAdding: .day, value: -12, to: now),
            billingPeriodEnd: Calendar.current.date(byAdding: .day, value: 18, to: now),
            isUnifiedBillingUser: true,
            history: history,
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
        if let raw = UserDefaults.standard.string(forKey: "billingEndpoint"),
           let url = URL(string: raw), !raw.isEmpty {
            return LiveBillingService(endpoint: url)
        }
        if let raw = ProcessInfo.processInfo.environment["GROK_BILLING_ENDPOINT"],
           let url = URL(string: raw), !raw.isEmpty {
            return LiveBillingService(endpoint: url)
        }
        return LiveBillingService()
    }
}
