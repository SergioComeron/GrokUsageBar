import XCTest
@testable import GrokUsageBarCore

final class AuthFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadPrefersTheAppOIDCEntryOverAnAPIKey() throws {
        let url = try writeSample()
        let session = try GrokAuthStore.loadSession(from: url)
        XCTAssertEqual(session.entryKey, oidcKey)
        XCTAssertEqual(session.accessToken, "access-old")
        XCTAssertEqual(session.email, "a@b.c")
    }

    func testTokenUpdatePreservesOtherKeysAndFields() throws {
        let url = try writeSample()
        let lock = try GrokAuthFileLock.acquireSync(authFileURL: url, timing: .advisory, heartbeat: false)
        defer { lock.release() }
        try GrokAuthStore.applyTokenUpdate(
            entryKey: oidcKey,
            accessToken: "access-new",
            refreshToken: "refresh-new",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            to: url,
            lock: lock
        )
        let root = try GrokAuthStore.readRoot(from: url)
        let api = root["xai::api_key"] as? [String: Any]
        XCTAssertEqual(api?["key"] as? String, "sk-test")
        XCTAssertEqual(api?["custom_flag"] as? Bool, true)
        let oidc = root[oidcKey] as? [String: Any]
        XCTAssertEqual(oidc?["key"] as? String, "access-new")
        XCTAssertEqual(oidc?["refresh_token"] as? String, "refresh-new")
        XCTAssertEqual(oidc?["future_field"] as? String, "keep-me")
        XCTAssertEqual(oidc?["email"] as? String, "a@b.c")
        XCTAssertEqual(oidc?["create_time"] as? String, "2024-01-01T00:00:00.000Z")
        XCTAssertNotNil(oidc?["expires_at"] as? String)
    }

    func testSignOutRemovesOnlyTheAppEntry() throws {
        let url = try writeSample()
        try GrokAuthStore.signOut(from: url)
        let root = try GrokAuthStore.readRoot(from: url)
        XCTAssertNil(root[oidcKey])
        let api = root["xai::api_key"] as? [String: Any]
        XCTAssertEqual(api?["key"] as? String, "sk-test")
        XCTAssertEqual(api?["custom_flag"] as? Bool, true)
    }

    func testSignOutDeletesTheFileWhenItWasTheOnlyEntry() throws {
        let url = directory.appendingPathComponent("auth.json")
        let only = [oidcKey: sampleOIDC()]
        let data = try JSONSerialization.data(withJSONObject: only)
        try data.write(to: url)
        try GrokAuthStore.signOut(from: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSignOutDoesNotDeleteWhileTheCLIHoldsTheLock() throws {
        let url = try writeSample()
        let held = try GrokAuthFileLock.acquireSync(authFileURL: url, timing: .advisory, heartbeat: false)
        defer { held.release() }
        let impatient = GrokAuthFileLock.Timing(
            timeout: 0.4,
            staleAfter: 60,
            confirmDelay: 12,
            heartbeatInterval: 5
        )
        XCTAssertThrowsError(try GrokAuthStore.signOut(from: url, lockTiming: impatient)) { error in
            XCTAssertEqual(error as? GrokAuthError, .lockBusy)
        }
        let session = try GrokAuthStore.loadSession(from: url)
        XCTAssertEqual(session.accessToken, "access-old")
        let root = try GrokAuthStore.readRoot(from: url)
        XCTAssertNotNil(root["xai::api_key"])
    }

    func testLockFileIsASiblingFileWithHolderInfo() throws {
        let url = directory.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: url)
        let lock = try GrokAuthFileLock.acquireSync(authFileURL: url, timing: .advisory, heartbeat: false)
        defer { lock.release() }
        let lockURL = GrokAuthFileLock.lockFileURL(for: url)
        XCTAssertEqual(lockURL.lastPathComponent, "auth.json.lock")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertTrue(lock.stillLive())
        let text = try String(contentsOf: lockURL, encoding: .utf8)
        let parts = text.split(separator: ":")
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotNil(Int(parts[0]))
        XCTAssertNotNil(Int(parts[1]))
    }

    func testSecondAcquireWaitsForTheHolder() throws {
        let url = directory.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: url)
        let timing = GrokAuthFileLock.Timing(timeout: 3, staleAfter: 60, confirmDelay: 12, heartbeatInterval: 5)
        let first = try GrokAuthFileLock.acquireSync(authFileURL: url, timing: timing, heartbeat: false)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = AcquireOutcome()
        Thread.detachNewThread {
            started.signal()
            let began = Date()
            if let second = try? GrokAuthFileLock.acquireSync(authFileURL: url, timing: timing, heartbeat: false) {
                outcome.acquired = true
                second.release()
            }
            outcome.elapsed = Date().timeIntervalSince(began)
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.35)
        first.release()
        XCTAssertEqual(finished.wait(timeout: .now() + 4), .success)
        XCTAssertTrue(outcome.acquired)
        XCTAssertGreaterThan(outcome.elapsed, 0.25)
    }

    func testStuckLiveHolderIsBrokenAfterConfirmation() throws {
        let url = directory.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: url)
        let holderTiming = GrokAuthFileLock.Timing(timeout: 2, staleAfter: 60, confirmDelay: 12, heartbeatInterval: 5)
        let holder = try GrokAuthFileLock.acquireSync(authFileURL: url, timing: holderTiming, heartbeat: false)
        defer { holder.release() }
        holder.rewriteHolderTimestampForTesting(Int(Date().timeIntervalSince1970) - 100)
        let breaker = GrokAuthFileLock.Timing(timeout: 2.2, staleAfter: 1, confirmDelay: 0.3, heartbeatInterval: 5)
        let began = Date()
        let acquired = try GrokAuthFileLock.acquireSync(authFileURL: url, timing: breaker, heartbeat: false)
        defer { acquired.release() }
        XCTAssertGreaterThan(Date().timeIntervalSince(began), 0.3)
        XCTAssertFalse(holder.stillLive())
        XCTAssertTrue(acquired.stillLive())
    }

    private let oidcKey = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"

    private final class AcquireOutcome: @unchecked Sendable {
        var elapsed: TimeInterval = 0
        var acquired = false
    }

    private func writeSample() throws -> URL {
        let url = directory.appendingPathComponent("auth.json")
        let root: [String: Any] = [
            "xai::api_key": [
                "key": "sk-test",
                "auth_mode": "api_key",
                "custom_flag": true,
            ],
            oidcKey: sampleOIDC(),
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        return url
    }

    private func sampleOIDC() -> [String: Any] {
        [
            "key": "access-old",
            "refresh_token": "refresh-old",
            "expires_at": "2020-01-01T00:00:00Z",
            "auth_mode": "oidc",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828",
            "email": "a@b.c",
            "create_time": "2024-01-01T00:00:00.000Z",
            "future_field": "keep-me",
        ]
    }
}
