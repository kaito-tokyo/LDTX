// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import LDTXCapture

struct CaptureSessionRuntimeFailurePolicyTests {
  @Test
  func mediaServicesResetRestartsCurrentSession() {
    #expect(
      CaptureSessionRuntimeFailurePolicy.action(
        errorCode: CaptureSessionRuntimeFailurePolicy.mediaServicesWereResetErrorCode,
        observedSessionIsCurrent: true
      ) == .restart)
  }

  @Test
  func errorsFromReplacedSessionAreDiscarded() {
    #expect(
      CaptureSessionRuntimeFailurePolicy.action(
        errorCode: CaptureSessionRuntimeFailurePolicy.mediaServicesWereResetErrorCode,
        observedSessionIsCurrent: false
      ) == .discard)
    #expect(
      CaptureSessionRuntimeFailurePolicy.action(
        errorCode: -1,
        observedSessionIsCurrent: false
      ) == .discard)
  }

  @Test
  func otherCurrentSessionErrorsAreReported() {
    #expect(
      CaptureSessionRuntimeFailurePolicy.action(
        errorCode: -1,
        observedSessionIsCurrent: true
      ) == .report)
  }
}
