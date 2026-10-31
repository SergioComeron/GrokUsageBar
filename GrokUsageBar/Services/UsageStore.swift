//
//  UsageStore.swift
//  GrokUsageBar
//

import AppKit
import Combine
import Foundation
import Network

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
    @Published private(set) var signOutError: String?
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
    @Published var alertThresholds: Set<Int> {
        didSet { UsageNotifier.enabledThresholds = alertThresholds }
    }
    @Published var paceAlertsEnabled: Bool {
        didSet { UsageNotifier.paceAlertsEnabled = paceAlertsEnabled }
    }

    private var billing: any BillingServing
    private var timer: Timer?
    private let refreshCoalescer = RefreshCoalescer()
    private var loginTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var sawUnreachablePath = false
    /// Bumped on sign-out so an in-flight refresh can't paint a session we just removed.
    private var sessionGeneration = 0

    private enum Keys {
        static let interval = "refreshIntervalMinutes"
    }

    init(billing: (any BillingServing)? = nil) {
        self.billing = billing ?? BillingServiceFactory.make()
        let stored = UserDefaults.standard.object(forKey: Keys.interval) as? Double
        self.refreshIntervalMinutes = stored ?? 10
        self.notificationsEnabled = UsageNotifier.isEnabled
        self.alertThresholds = UsageNotifier.enabledThresholds
        self.paceAlertsEnabled = UsageNotifier.paceAlertsEnabled
        scheduleTimer()
        startSystemRefreshObservers()
        Task {
            if UsageNotifier.isEnabled {
                await UsageNotifier.requestAuthorizationIfNeeded()
            }
            await refresh()
        }
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pathMonitor?.cancel()
    }

    /// Last good snapshot, including one we're showing as stale.
    var usage: BillingUsage? {
        switch state {
        case .loaded(let usage), .stale(let usage, _):
            return usage
        default:
            return nil
        }
    }

    var isStale: Bool {
        if case .stale = state { return true }
        return false
    }

    var isMockData: Bool {
        billing is MockBillingService
    }

    func refresh() async {
        if loginProgress != .idle, loginProgress != .finishing {
            return
        }
        let generation = sessionGeneration
        await refreshCoalescer.run { [weak self] in
            await self?.performRefresh(generation: generation)
        }
    }

    private func performRefresh(generation: Int) async {
        guard generation == sessionGeneration else { return }
        let previous = usage
        if let previous {
            state = .stale(previous, nil)
        } else {
            state = .loading
        }

        let session: GrokSession
        do {
            session = try await GrokAuthStore.validSession()
            guard generation == sessionGeneration else { return }
            sessionEmail = session.email
        } catch let error as GrokAuthError {
            guard generation == sessionGeneration else { return }
            applyAuthFailure(error, previous: previous)
            return
        } catch {
            guard generation == sessionGeneration else { return }
            applyLoadFailure(error.localizedDescription, previous: previous)
            return
        }

        do {
            let usage = try await billing.fetchUsage(session: session)
            guard generation == sessionGeneration else { return }
            await applyLoaded(usage)
        } catch let error as BillingServiceError where error == .unauthorized {
            do {
                let renewed = try await GrokAuthStore.validSession(
                    forceRefresh: true,
                    rejectedAccessToken: session.accessToken
                )
                guard generation == sessionGeneration else { return }
                sessionEmail = renewed.email
                let usage = try await billing.fetchUsage(session: renewed)
                guard generation == sessionGeneration else { return }
                await applyLoaded(usage)
            } catch let error as GrokAuthError {
                guard generation == sessionGeneration else { return }
                applyAuthFailure(error, previous: previous)
            } catch {
                guard generation == sessionGeneration else { return }
                applyLoadFailure(error.localizedDescription, previous: previous)
            }
        } catch {
            guard generation == sessionGeneration else { return }
            applyLoadFailure(error.localizedDescription, previous: previous)
        }
    }

    private func applyLoaded(_ usage: BillingUsage) async {
        // Sign-out may have removed the entry while this fetch was in flight.
        guard GrokAuthStore.hasSession() else {
            sessionEmail = nil
            state = .needsLogin
            return
        }
        state = .loaded(usage)
        await UsageNotifier.evaluate(usage)
    }

    /// Auth failures that mean "no session" clear the bar. A lock or file
    /// hiccup keeps the last percentage and marks it stale.
    private func applyAuthFailure(_ error: GrokAuthError, previous: BillingUsage?) {
        switch error {
        case .authFileMissing, .noSession, .tokenExpired, .refreshUnavailable, .loginCancelled:
            sessionEmail = nil
            state = .needsLogin
        default:
            applyLoadFailure(error.localizedDescription, previous: previous)
        }
    }

    private func applyLoadFailure(_ message: String, previous: BillingUsage?) {
        if let previous {
            state = .stale(previous, message)
        } else {
            state = .failed(message)
        }
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

    /// Removes this app's account from ~/.grok/auth.json. Other entries stay.
    func signOut() {
        cancelLogin()
        signOutError = nil
        sessionGeneration += 1
        let generation = sessionGeneration
        Task {
            let failure: String? = await {
                do {
                    try await GrokAuthStore.signOutAsync()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }()
            guard generation == self.sessionGeneration else { return }
            if let failure {
                self.signOutError = failure
                if GrokAuthStore.hasSession() {
                    await self.refresh()
                }
            } else {
                self.sessionEmail = nil
                self.state = .needsLogin
                self.signOutError = nil
            }
        }
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

    /// Wake and a network that just came back both fetch promptly instead of
    /// waiting out the refresh interval.
    private func startSystemRefreshObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }

        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if reachable, self.sawUnreachablePath {
                    self.sawUnreachablePath = false
                    await self.refresh()
                } else if !reachable {
                    self.sawUnreachablePath = true
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.sergiocomeron.GrokUsageBar.path"))
    }
}
