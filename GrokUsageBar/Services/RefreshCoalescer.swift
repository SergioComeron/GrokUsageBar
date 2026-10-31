//
//  RefreshCoalescer.swift
//  GrokUsageBar
//
//  Overlapping refresh triggers (timer, panel, login, wake) share one in-flight
//  fetch. A request that arrives while a fetch is running schedules a single
//  follow-up, so a login that lands mid-refresh still loads the new session
//  without stacking one network call per click.
//

import Foundation

actor RefreshCoalescer {
    private var task: Task<Void, Never>?
    private var rerun = false
    private var operation: (@Sendable () async -> Void)?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        self.operation = operation
        rerun = true
        if let task {
            await task.value
            return
        }
        let created = Task { await self.drain() }
        task = created
        await created.value
    }

    private func drain() async {
        while rerun {
            rerun = false
            let operation = self.operation
            await operation?()
        }
        task = nil
    }
}
