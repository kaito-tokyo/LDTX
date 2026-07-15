// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LDTXDash

final class DASHUploadFinalizationStateTests: XCTestCase {
  func testFinalizationRetainsUploadFailureAfterAllUploadsComplete() throws {
    var state = DASHUploadFinalizationState()
    state.beginUpload()
    state.beginUpload()
    state.completeUpload(error: TestError.uploadFailed)
    state.completeUpload()

    XCTAssertEqual(state.pendingCount, 0)
    XCTAssertThrowsError(try state.validateFinished()) { error in
      XCTAssertEqual(
        error as? DASHUploadFinalizationError,
        .uploadFailed(TestError.uploadFailed.localizedDescription))
    }
  }

  func testFinalizationRetainsProcessingFailureWithoutAnUpload() {
    var state = DASHUploadFinalizationState()
    state.recordFailure(TestError.uploadFailed)

    XCTAssertThrowsError(try state.validateFinished()) { error in
      XCTAssertEqual(
        error as? DASHUploadFinalizationError,
        .uploadFailed(TestError.uploadFailed.localizedDescription))
    }
  }

  private enum TestError: Error, LocalizedError {
    case uploadFailed
    var errorDescription: String? { "HTTP upload failed" }
  }
}
