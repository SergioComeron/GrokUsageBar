//
//  UsageStore.swift
//  GrokUsageBar
//

import AppKit
import Combine
import Foundation

enum LoginProgress: Equatable {
    case idle
    case starting
    case waiting(userCode: String, verificationURL: URL)
    case finishing
    case failed(String)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageLoadState = .idle
    @Published private(set) var sessionEmail: String?
    @Published private(set) var loginProgress: LoginProgress = .idle
    @Published var refreshIntervalMinutes: Double {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: Keys.interval)
            scheduleTimer()
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            UsageNotifier.isEnabled = notificationsEnabled
            if notificationsEnabled {
                Task { await UsageNotifier.requestAuthorizationIfNeeded() }
            }
        }
    }

    private var billing: any BillingServing
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?

    private enum Keys {
        static let interval = "refreshIntervalMinutes"
    }

    init(billing: (any BillingServing)? = nil) {
        self.billing = billing ?? BillingServiceFactory.make()
        let stored = UserDefaults.standard.object(forKey: Keys.interval) as? Double
        self.refreshIntervalMinutes = stored ?? 10
        self.notificationsEnabled = UsageNotifier.isEnabled
        scheduleTimer()
        Task {
            if UsageNotifier.isEnabled {
                await UsageNotifier.requestAuthorizationIfNeeded()
            }
            await refresh()
        }
    }

    var usage: BillingUsage? {
        if case .loaded(let u) = state { return u }
        return nil
    }

    var isMockData: Bool {
        billing is MockBillingService
    }

    func refresh() async {
        if loginProgress != .idle, loginProgress != .finishing {
            return
        }
        refreshTask?.cancel()
        state = .loading

        let session: GrokSession
        do {
            session = try await GrokAuthStore.validSession()
            sessionEmail = session.email
        } catch let error as GrokAuthError {
            state = Self.mapAuthError(error)
            return
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        do {
            let usage = try await billing.fetchUsage(session: session)
            await applyLoaded(usage)
        } catch let error as BillingServiceError where error == .unauthorized {
            // Access token rejected: force one OIDC refresh and retry once.
            do {
                let renewed = try await GrokAuthStore.validSession(forceRefresh: true)
                sessionEmail = renewed.email
                let usage = try await billing.fetchUsage(session: renewed)
                await applyLoaded(usage)
            } catch let error as GrokAuthError {
                state = Self.mapAuthError(error)
            } catch {
                state = .failed(error.localizedDescription)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func applyLoaded(_ usage: BillingUsage) async {
        state = .loaded(usage)
        await UsageNotifier.evaluate(usage)
    }

    func openBillingPage() {
        if let url = URL(string: "https://grok.com/?_s=billing") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginHint() {
        if let url = URL(string: "https://accounts.x.ai/oauth2/device") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Device-code sign-in in the browser. Grok Build does not need to be installed.
    func startLogin() {
        loginTask?.cancel()
        loginTask = Task { await runLogin() }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginProgress = .idle
    }

    func signOut() {
        cancelLogin()
        GrokAuthStore.signOut()
        sessionEmail = nil
        state = .needsLogin
    }

    private func runLogin() async {
        loginProgress = .starting
        do {
            let pending = try await GrokDeviceLogin.start()
            loginProgress = .waiting(userCode: pending.userCode, verificationURL: pending.verificationURL)
            NSWorkspace.shared.open(pending.verificationURL)
            let session = try await GrokDeviceLogin.waitForSession(pending)
            sessionEmail = session.email
            loginProgress = .finishing
            await refresh()
            loginProgress = .idle
        } catch is CancellationError {
            loginProgress = .idle
        } catch let error as GrokAuthError where error == .loginCancelled {
            loginProgress = .idle
        } catch {
            loginProgress = .failed(error.localizedDescription)
            if !GrokAuthStore.hasSession() {
                state = .needsLogin
            }
        }
    }

    private static func mapAuthError(_ error: GrokAuthError) -> UsageLoadState {
        switch error {
        case .authFileMissing, .noSession, .tokenExpired, .refreshUnavailable, .loginCancelled:
            return .needsLogin
        default:
            return .failed(error.localizedDescription)
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
