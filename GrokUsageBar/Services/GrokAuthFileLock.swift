//
//  GrokAuthFileLock.swift
//  GrokUsageBar
//
//  Cross-process lock for `~/.grok/auth.json`, matching the grok CLI
//  (`auth/manager/lock.rs` in grok-build):
//
//  - The lock is a regular file named `auth.json.lock` next to `auth.json`
//    (never a directory). Exclusive `flock(LOCK_EX)`.
//  - After acquiring, the holder writes `PID:UNIX_TIMESTAMP` into that file
//    and, while a refresh is in flight, rewrites it every 5s. The CLI uses
//    the timestamp to tell a live holder from a stuck one, and the heartbeat
//    so a Mac that slept doesn't look stuck the instant it wakes.
//  - Waiters block in `flock` (kernel FIFO) until `timeout`. Dead holders
//    (PID gone) are broken immediately by unlinking the lock file and locking
//    a fresh inode. A live holder whose timestamp is older than 60s is broken
//    only after it stays stale for another 12s of awake time — unlinking at
//    wake+0 would let two processes spend the same refresh token.
//  - Before sending a refresh token or writing `auth.json`, the holder checks
//    that its fd still refers to the live inode. A sibling that broke a stuck
//    lock leaves this fd on a deleted inode; the flock there no longer
//    excludes anyone.
//
//  Refresh waits up to 45s (the CLI's `REFRESH_LOCK_TIMEOUT`). Sign-out and
//  login writes wait up to 10s (`AUTH_LOCK_TIMEOUT`) and do not heartbeat.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum GrokAuthLockError: Error, Equatable {
    case timedOut
    case ioFailed
}

final class GrokAuthFileLock: @unchecked Sendable {
    /// CLI `STALE_LOCK_TIMEOUT_SECS`.
    static let staleTimeout: TimeInterval = 60
    /// CLI `STUCK_LIVE_CONFIRM_DELAY`.
    static let stuckLiveConfirm: TimeInterval = 12
    /// CLI `LOCK_HEARTBEAT_INTERVAL`.
    static let heartbeatInterval: TimeInterval = 5
    /// CLI `REFRESH_LOCK_TIMEOUT` — held across the token request.
    static let refreshTimeout: TimeInterval = 45
    /// CLI `AUTH_LOCK_TIMEOUT` — sign-out / login writes.
    static let advisoryTimeout: TimeInterval = 10
    /// CLI `LOCK_TIMEOUT_WAIT` — pause before adopting a sibling token.
    static let adoptWait: TimeInterval = 2

    struct Timing: Equatable, Sendable {
        var timeout: TimeInterval
        var staleAfter: TimeInterval
        var confirmDelay: TimeInterval
        var heartbeatInterval: TimeInterval

        static let refresh = Timing(
            timeout: GrokAuthFileLock.refreshTimeout,
            staleAfter: GrokAuthFileLock.staleTimeout,
            confirmDelay: GrokAuthFileLock.stuckLiveConfirm,
            heartbeatInterval: GrokAuthFileLock.heartbeatInterval
        )

        static let advisory = Timing(
            timeout: GrokAuthFileLock.advisoryTimeout,
            staleAfter: GrokAuthFileLock.staleTimeout,
            confirmDelay: GrokAuthFileLock.stuckLiveConfirm,
            heartbeatInterval: GrokAuthFileLock.heartbeatInterval
        )
    }

    private let stateLock = NSLock()
    private var fd: Int32
    private let lockPath: String
    private var released = false
    private let heartbeatEvery: TimeInterval

    private init(fd: Int32, lockPath: String, heartbeatEvery: TimeInterval?) {
        self.fd = fd
        self.lockPath = lockPath
        self.heartbeatEvery = heartbeatEvery ?? 0
        if heartbeatEvery != nil {
            startHeartbeat()
        }
    }

    deinit {
        release()
    }

    static func lockFileURL(for authFileURL: URL) -> URL {
        authFileURL.appendingPathExtension("lock")
    }

    /// Blocks the calling thread. Refresh calls `acquire` so this stays off the main thread.
    static func acquireSync(
        authFileURL: URL,
        timing: Timing,
        heartbeat: Bool
    ) throws -> GrokAuthFileLock {
        let lockURL = lockFileURL(for: authFileURL)
        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw GrokAuthLockError.ioFailed
        }
        let path = lockURL.path
        if let fd = try phase1(path: path, staleAfter: timing.staleAfter) {
            return GrokAuthFileLock(fd: fd, lockPath: path, heartbeatEvery: heartbeat ? timing.heartbeatInterval : nil)
        }

        let confirm = timing.confirmDelay
        let phase2Budget = timing.timeout >= confirm ? timing.timeout - confirm : timing.timeout
        if let fd = try phase2(path: path, budget: phase2Budget) {
            return GrokAuthFileLock(fd: fd, lockPath: path, heartbeatEvery: heartbeat ? timing.heartbeatInterval : nil)
        }

        if let fd = try phase3(
            path: path,
            staleAfter: timing.staleAfter,
            confirmDelay: confirm,
            allowConfirm: timing.timeout >= confirm
        ) {
            return GrokAuthFileLock(fd: fd, lockPath: path, heartbeatEvery: heartbeat ? timing.heartbeatInterval : nil)
        }
        throw GrokAuthLockError.timedOut
    }

    static func acquire(
        authFileURL: URL,
        timing: Timing,
        heartbeat: Bool
    ) async throws -> GrokAuthFileLock {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let lock = try acquireSync(authFileURL: authFileURL, timing: timing, heartbeat: heartbeat)
                    continuation.resume(returning: lock)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// True while this fd is still the inode at `auth.json.lock`.
    func stillLive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if released || fd < 0 { return false }
        return Self.inodesMatch(fd: fd, path: lockPath)
    }

    func release() {
        stateLock.lock()
        if released {
            stateLock.unlock()
            return
        }
        released = true
        let openFD = fd
        fd = -1
        stateLock.unlock()
        if openFD >= 0 {
            _ = flock(openFD, LOCK_UN)
            close(openFD)
        }
    }

    /// Test hook: make this holder look stuck without dropping the flock.
    func rewriteHolderTimestampForTesting(_ timestamp: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if released || fd < 0 { return }
        Self.writeHolderInfo(fd: fd, timestamp: timestamp)
    }

    // MARK: - Acquire phases

    private static func phase1(path: String, staleAfter: TimeInterval) throws -> Int32? {
        for _ in 0..<3 {
            switch tryAcquireOnce(path: path, stuckLive: .wait, staleAfter: staleAfter) {
            case .acquired(let fd):
                return fd
            case .failed:
                throw GrokAuthLockError.ioFailed
            case .staleUnlinked:
                continue
            case .busy:
                return nil
            }
        }
        return nil
    }

    private static func phase2(path: String, budget: TimeInterval) throws -> Int32? {
        let deadline = Date().addingTimeInterval(max(budget, 0))
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            switch blockingAcquire(path: path, timeout: remaining) {
            case .acquired(let fd):
                return fd
            case .retry:
                continue
            case .timedOut:
                return nil
            case .failed:
                throw GrokAuthLockError.ioFailed
            }
        }
    }

    private static func phase3(
        path: String,
        staleAfter: TimeInterval,
        confirmDelay: TimeInterval,
        allowConfirm: Bool
    ) throws -> Int32? {
        var sawStuckLive = false
        for _ in 0..<2 {
            switch tryAcquireOnce(path: path, stuckLive: .wait, staleAfter: staleAfter) {
            case .acquired(let fd):
                return fd
            case .staleUnlinked:
                continue
            case .busy:
                sawStuckLive = true
            case .failed:
                throw GrokAuthLockError.ioFailed
            }
            break
        }
        guard sawStuckLive, allowConfirm else { return nil }
        Thread.sleep(forTimeInterval: confirmDelay)
        for _ in 0..<2 {
            switch tryAcquireOnce(path: path, stuckLive: .break, staleAfter: staleAfter) {
            case .acquired(let fd):
                return fd
            case .staleUnlinked:
                continue
            case .busy:
                return nil
            case .failed:
                throw GrokAuthLockError.ioFailed
            }
        }
        return nil
    }

    // MARK: - flock

    private enum StuckLivePolicy {
        case wait
        case `break`
    }

    private enum Attempt {
        case acquired(Int32)
        case busy
        case staleUnlinked
        case failed
    }

    private enum BlockingOutcome {
        case acquired(Int32)
        case retry
        case timedOut
        case failed
    }

    private final class BlockingGate: @unchecked Sendable {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var fd: Int32 = -1
        var acquired = false
        var abandoned = false
        var inodeMismatch = false
        var failed = false
    }

    private static func tryAcquireOnce(
        path: String,
        stuckLive: StuckLivePolicy,
        staleAfter: TimeInterval
    ) -> Attempt {
        guard let fd = openLockFile(path) else { return .failed }
        switch flockExclusive(fd: fd, nonBlocking: true) {
        case .acquired:
            writeHolderInfo(fd: fd)
            if inodesMatch(fd: fd, path: path) {
                return .acquired(fd)
            }
            _ = flock(fd, LOCK_UN)
            close(fd)
            return .staleUnlinked
        case .wouldBlock:
            let state = holderState(fd: fd, staleAfter: staleAfter)
            close(fd)
            let breakable: Bool
            switch state {
            case .dead:
                breakable = true
            case .stuckLive:
                breakable = stuckLive == .break
            case .alive:
                breakable = false
            }
            if breakable {
                if unlinkPath(path) { return .staleUnlinked }
                return .busy
            }
            return .busy
        case .failed:
            close(fd)
            return .failed
        }
    }

    private static func blockingAcquire(path: String, timeout: TimeInterval) -> BlockingOutcome {
        let gate = BlockingGate()
        Thread.detachNewThread {
            guard let fd = openLockFile(path) else {
                gate.lock.lock()
                gate.failed = true
                gate.lock.unlock()
                gate.semaphore.signal()
                return
            }
            switch flockExclusive(fd: fd, nonBlocking: false) {
            case .acquired:
                break
            default:
                close(fd)
                gate.lock.lock()
                gate.failed = true
                gate.lock.unlock()
                gate.semaphore.signal()
                return
            }
            gate.lock.lock()
            let abandoned = gate.abandoned
            let live = inodesMatch(fd: fd, path: path)
            if abandoned || !live {
                gate.inodeMismatch = !live && !abandoned
                gate.lock.unlock()
                _ = flock(fd, LOCK_UN)
                close(fd)
                gate.semaphore.signal()
                return
            }
            writeHolderInfo(fd: fd)
            gate.fd = fd
            gate.acquired = true
            gate.lock.unlock()
            gate.semaphore.signal()
        }

        _ = gate.semaphore.wait(timeout: .now() + timeout)
        gate.lock.lock()
        if gate.acquired {
            let fd = gate.fd
            gate.lock.unlock()
            return .acquired(fd)
        }
        gate.abandoned = true
        let mismatch = gate.inodeMismatch
        let failed = gate.failed
        gate.lock.unlock()
        if failed { return .failed }
        if mismatch { return .retry }
        return .timedOut
    }

    private enum FlockResult {
        case acquired
        case wouldBlock
        case failed
    }

    private static func flockExclusive(fd: Int32, nonBlocking: Bool) -> FlockResult {
        let flags = nonBlocking ? (LOCK_EX | LOCK_NB) : LOCK_EX
        while true {
            if flock(fd, flags) == 0 { return .acquired }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK { return .wouldBlock }
            return .failed
        }
    }

    // MARK: - Holder info

    private enum HolderState {
        case dead
        case stuckLive
        case alive
    }

    private static func holderState(fd: Int32, staleAfter: TimeInterval) -> HolderState {
        if let holder = readHolderInfo(fd: fd) {
            if !isProcessAlive(holder.pid) { return .dead }
            let age = Date().timeIntervalSince1970 - TimeInterval(holder.timestamp)
            if age > staleAfter { return .stuckLive }
            return .alive
        }
        if let age = mtimeAge(fd: fd), age > staleAfter {
            return .stuckLive
        }
        return .alive
    }

    private static func writeHolderInfo(fd: Int32, pid: Int32 = getpid(), timestamp: Int? = nil) {
        let stamp = timestamp ?? Int(Date().timeIntervalSince1970)
        let text = "\(pid):\(stamp)"
        let bytes = Array(text.utf8)
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        bytes.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        _ = fsync(fd)
    }

    private static func readHolderInfo(fd: Int32) -> (pid: Int32, timestamp: Int)? {
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = lseek(fd, 0, SEEK_SET)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let n = read(fd, base, raw.count)
            return n > 0 ? Int(n) : 0
        }
        guard count > 0,
              let text = String(bytes: buffer.prefix(count), encoding: .utf8)
        else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let pid = Int32(parts[0]), let stamp = Int(parts[1]), pid > 0 else {
            return nil
        }
        return (pid, stamp)
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func mtimeAge(fd: Int32) -> TimeInterval? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = TimeInterval(info.st_mtime)
        #else
        let modified = TimeInterval(info.st_mtim.tv_sec)
        #endif
        return Date().timeIntervalSince1970 - modified
    }

    private static func inodesMatch(fd: Int32, path: String) -> Bool {
        var fdInfo = stat()
        var pathInfo = stat()
        guard fstat(fd, &fdInfo) == 0 else { return false }
        let rc = path.withCString { cstr in
            stat(cstr, &pathInfo)
        }
        guard rc == 0 else { return false }
        return fdInfo.st_ino == pathInfo.st_ino && fdInfo.st_dev == pathInfo.st_dev
    }

    private static func openLockFile(_ path: String) -> Int32? {
        let fd: Int32 = path.withCString { cstr in
            #if canImport(Darwin)
            Darwin.open(cstr, O_RDWR | O_CREAT, mode_t(0o600))
            #elseif canImport(Glibc)
            Glibc.open(cstr, O_RDWR | O_CREAT, mode_t(0o600))
            #else
            -1
            #endif
        }
        guard fd >= 0 else { return nil }
        _ = fchmod(fd, mode_t(0o600))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func unlinkPath(_ path: String) -> Bool {
        path.withCString { cstr in
            unlink(cstr) == 0
        }
    }

    private func startHeartbeat() {
        let interval = heartbeatEvery
        Thread.detachNewThread { [weak self] in
            while let self {
                var slept: TimeInterval = 0
                while slept < interval {
                    if self.isStopped { return }
                    Thread.sleep(forTimeInterval: 0.05)
                    slept += 0.05
                }
                if self.isStopped { return }
                self.beat()
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return released
    }

    private func beat() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if released || fd < 0 { return }
        Self.writeHolderInfo(fd: fd)
    }
}
