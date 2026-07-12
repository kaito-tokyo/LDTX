// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public protocol ProgramRuntimeScheduling: Sendable {
    var nowNanoseconds: UInt64 { get }
    var uptimeSeconds: TimeInterval { get }

}

public struct SystemProgramRuntimeScheduler: ProgramRuntimeScheduling {
    public init() {}

    public var nowNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public var uptimeSeconds: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

}

/// A deterministic scheduler whose time advances only when directed by a test.
public final class ManualProgramRuntimeScheduler: ProgramRuntimeScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTimeNanoseconds: UInt64

    public init(nowNanoseconds: UInt64 = 0) {
        currentTimeNanoseconds = nowNanoseconds
    }

    public var nowNanoseconds: UInt64 {
        lock.withLock { currentTimeNanoseconds }
    }

    public var uptimeSeconds: TimeInterval {
        TimeInterval(nowNanoseconds) / 1_000_000_000
    }

    public func advance(byNanoseconds deltaNanoseconds: UInt64) {
        advance(toNanoseconds: nowNanoseconds &+ deltaNanoseconds)
    }

    public func advance(toNanoseconds newTimeNanoseconds: UInt64) {
        lock.withLock {
            guard newTimeNanoseconds >= currentTimeNanoseconds else {
                return
            }
            currentTimeNanoseconds = newTimeNanoseconds
        }
    }
}
