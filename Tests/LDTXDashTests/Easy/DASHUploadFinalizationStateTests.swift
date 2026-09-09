// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXDash

@Suite
struct DASHUploadFinalizationStateUnitTestSuite {
  @Test func finalizationRetainsUploadFailureAfterAllUploadsComplete() throws {
    var state = DASHUploadFinalizationState()
    state.beginUpload()
    state.beginUpload()
    state.completeUpload(error: TestError.uploadFailed)
    state.completeUpload()

    #expect(state.pendingCount == 0)
    #expect(throws: DASHUploadFinalizationError.self) {
      try state.validateFinished()
    }
    #expect(
      throws: DASHUploadFinalizationError.uploadFailed(TestError.uploadFailed.localizedDescription)
    ) {
      try state.validateFinished()
    }
  }

  @Test func finalizationRetainsProcessingFailureWithoutAnUpload() {
    var state = DASHUploadFinalizationState()
    state.recordFailure(TestError.uploadFailed)

    #expect(
      throws: DASHUploadFinalizationError.uploadFailed(TestError.uploadFailed.localizedDescription)
    ) {
      try state.validateFinished()
    }
  }

  private enum TestError: Error, LocalizedError {
    case uploadFailed
    var errorDescription: String? { "HTTP upload failed" }
  }
}
