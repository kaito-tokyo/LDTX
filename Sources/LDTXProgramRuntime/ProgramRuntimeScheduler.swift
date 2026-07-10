// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public protocol ProgramRuntimeScheduling: Sendable {
    var nowNanoseconds: UInt64 { get }
    var uptimeSeconds: TimeInterval { get }

    func sleep(nanoseconds: UInt64) async
}

public struct SystemProgramRuntimeScheduler: ProgramRuntimeScheduling {
    public init() {}

    public var nowNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public var uptimeSeconds: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// A deterministic scheduler whose time advances only when directed by a test.
public final class ManualProgramRuntimeScheduler: ProgramRuntimeScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTimeNanoseconds: UInt64
    private var waitersByID: [UUID: Waiter] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    public init(nowNanoseconds: UInt64 = 0) {
        currentTimeNanoseconds = nowNanoseconds
    }

    public var nowNanoseconds: UInt64 {
        lock.withLock { currentTimeNanoseconds }
    }

    public var uptimeSeconds: TimeInterval {
        TimeInterval(nowNanoseconds) / 1_000_000_000
    }

    public var pendingSleepCount: Int {
        lock.withLock { waitersByID.count }
    }

    public func sleep(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(
                    id: waiterID,
                    nanoseconds: nanoseconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            cancelWaiter(id: waiterID)
        }
    }

    @discardableResult
    public func advance(byNanoseconds deltaNanoseconds: UInt64) -> Int {
        advance(toNanoseconds: nowNanoseconds &+ deltaNanoseconds)
    }

    @discardableResult
    public func advance(toNanoseconds newTimeNanoseconds: UInt64) -> Int {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard newTimeNanoseconds >= currentTimeNanoseconds else {
                return []
            }
            currentTimeNanoseconds = newTimeNanoseconds
            let dueWaiterIDs = waitersByID.compactMap { id, waiter in
                waiter.deadlineNanoseconds <= newTimeNanoseconds ? id : nil
            }
            return dueWaiterIDs.compactMap { id in
                waitersByID.removeValue(forKey: id)?.continuation
            }
        }
        for continuation in continuations {
            continuation.resume()
        }
        return continuations.count
    }

    private func registerWaiter(
        id: UUID,
        nanoseconds: UInt64,
        continuation: CheckedContinuation<Void, Never>
    ) {
        let shouldResume = lock.withLock { () -> Bool in
            if cancelledWaiterIDs.remove(id) != nil {
                return true
            }
            waitersByID[id] = Waiter(
                deadlineNanoseconds: currentTimeNanoseconds &+ nanoseconds,
                continuation: continuation
            )
            return false
        }
        if shouldResume {
            continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let waiter = waitersByID.removeValue(forKey: id) {
                return waiter.continuation
            }
            cancelledWaiterIDs.insert(id)
            return nil
        }
        continuation?.resume()
    }
}

private struct Waiter: @unchecked Sendable {
    var deadlineNanoseconds: UInt64
    var continuation: CheckedContinuation<Void, Never>
}
