// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXCapture
import Testing

@Suite(.tags(.easy))
struct CaptureSessionRuntimeFailurePolicyUnitTestSuite {
  @Test("LUB-1008: Media services reset restarts current session")
  func mediaServicesResetRestartsCurrentSession() {
    #expect(
      CaptureSessionRuntimeFailurePolicy.action(
        errorCode: CaptureSessionRuntimeFailurePolicy.mediaServicesWereResetErrorCode,
        observedSessionIsCurrent: true
      ) == .restart)
  }

  @Test("LUB-1008: Errors from replaced session are discarded")
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

  @Test("LUB-1008: Other current session errors are reported")
  func otherCurrentSessionErrorsAreReported() {
    #expect(
      CaptureSessionRuntimeFailurePolicy.action(
        errorCode: -1,
        observedSessionIsCurrent: true
      ) == .report)
  }
}
