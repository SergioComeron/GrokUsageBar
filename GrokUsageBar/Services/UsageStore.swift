//
//  UsageStore.swift
//  GrokUsageBar
//

import AppKit
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageLoadState = .idle
    @Published private(set) var sessionEmail: String?
    @Published var refreshIntervalMinutes: Double {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: Keys.interval)
            scheduleTimer()
        }
    }

    private var billing: any BillingServing
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    private enum Keys {
        static let interval = "refreshIntervalMinutes"
    }

    init(billing: (any BillingServing)? = nil) {
        self.billing = billing ?? BillingServiceFactory.make()
        let stored = UserDefaults.standard.object(forKey: Keys.interval) as? Double
        self.refreshIntervalMinutes = stored ?? 10
        scheduleTimer()
        Task { await refresh() }
    }

    var usage: BillingUsage? {
        if case .loaded(let u) = state { return u }
        return nil
    }

    var isMockData: Bool {
        billing is MockBillingService
    }

    func refresh() async {
        refreshTask?.cancel()
        state = .loading

        let session: GrokSession
        do {
            session = try GrokAuthStore.loadSession()
            sessionEmail = session.email
            if let exp = session.expiresAt, exp < Date().addingTimeInterval(-60) {
                // Soft check: still try; live API may reject.
            }
        } catch let error as GrokAuthError {
            state = error == .authFileMissing || error == .noSession
                ? .needsLogin
                : .failed(error.localizedDescription)
            return
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        do {
            let usage = try await billing.fetchUsage(session: session)
            state = .loaded(usage)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openBillingPage() {
        // Same destination Grok Build suggests for OAuth accounts.
        if let url = URL(string: "https://grok.com/?_s=billing") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginHint() {
        // No GUI login yet — point at the CLI.
        if let url = URL(string: "https://grok.com") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = max(60, refreshIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
