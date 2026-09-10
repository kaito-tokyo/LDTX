// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXProgramRuntime

extension LDTXIntegrationTestSuite {
  @Suite
  struct LowFrequencyUpdateRegistryIntegrationTestSuite {
    @Test func registrationReceivesNotificationsUntilCancelled() {
      let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
      let callback = LockedCounter()
      let registration = registry.register {
        callback.increment()
      }

      registry.notifySubscribersForTesting()
      registration.cancel()
      registry.notifySubscribersForTesting()

      #expect(callback.value == 1)
      #expect(registry.registrationCountForTesting == 0)
    }

    @Test func registrationCanCancelItselfWithoutDeadlocking() {
      let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
      let callback = LockedCounter()
      let holder = RegistrationHolder()
      holder.registration = registry.register {
        callback.increment()
        holder.registration?.cancel()
      }

      registry.notifySubscribersForTesting()
      registry.notifySubscribersForTesting()

      #expect(callback.value == 1)
      #expect(registry.registrationCountForTesting == 0)
    }

    @Test func externalCancellationWaitsForRunningCallbackAndPreventsFutureCallbacks() {
      let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
      let callback = LockedCounter()
      let callbackStarted = DispatchSemaphore(value: 0)
      let allowCallbackToFinish = DispatchSemaphore(value: 0)
      let notificationFinished = DispatchSemaphore(value: 0)
      let cancellationFinished = DispatchSemaphore(value: 0)
      let registration = registry.register {
        callbackStarted.signal()
        _ = allowCallbackToFinish.wait(timeout: .now() + 2)
        callback.increment()
      }

      DispatchQueue.global().async {
        registry.notifySubscribersForTesting()
        notificationFinished.signal()
      }
      #expect(callbackStarted.wait(timeout: .now() + 2) == .success)

      DispatchQueue.global().async {
        registration.cancel()
        cancellationFinished.signal()
      }
      #expect(cancellationFinished.wait(timeout: .now() + 0.05) == .timedOut)

      allowCallbackToFinish.signal()
      #expect(notificationFinished.wait(timeout: .now() + 2) == .success)
      #expect(cancellationFinished.wait(timeout: .now() + 2) == .success)

      registry.notifySubscribersForTesting()
      #expect(callback.value == 1)
      #expect(registry.registrationCountForTesting == 0)
    }

    @Test func shutdownRejectsFutureRegistrations() {
      let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
      registry.shutdown()
      let callback = LockedCounter()
      let registration = registry.register {
        callback.increment()
      }

      registry.notifySubscribersForTesting()
      registration.cancel()

      #expect(callback.value == 0)
      #expect(registry.registrationCountForTesting == 0)
    }
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private final class RegistrationHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRegistration: LowFrequencyUpdateRegistration?

  var registration: LowFrequencyUpdateRegistration? {
    get { lock.withLock { storedRegistration } }
    set { lock.withLock { storedRegistration = newValue } }
  }
}
