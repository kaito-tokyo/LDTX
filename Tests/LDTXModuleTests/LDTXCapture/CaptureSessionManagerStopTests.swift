// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Dispatch
@testable import LDTXCapture
import Synchronization
import Testing

@Suite(.tags(.easy)) struct CaptureSessionManagerStopUnitTestSuite {
  @Test("A requested stop runs after the caller releases its last manager reference")
  func stopRunsAfterCallerReleasesManager() async {
    let sessionQueue = DispatchQueue(label: "CaptureSessionManagerStopTests.session")
    // Hold the session queue so the caller's release happens before the stop
    // work runs, as it does when Workspace close drops its capture services.
    sessionQueue.suspend()
    var manager: CaptureSessionManager? = CaptureSessionManager(
      allowedVideoDeviceIDs: nil, sessionQueue: sessionQueue)
    weak let released = manager
    let managerWasAlive = Mutex<Bool?>(nil)

    await withCheckedContinuation { continuation in
      manager?.stop {
        managerWasAlive.withLock { $0 = released != nil }
        continuation.resume()
      }
      manager = nil
      sessionQueue.resume()
    }

    #expect(managerWasAlive.withLock { $0 } == true)
    sessionQueue.sync {}
    #expect(released == nil)
  }
}
