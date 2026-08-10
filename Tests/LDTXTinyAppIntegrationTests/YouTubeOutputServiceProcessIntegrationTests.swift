// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppCore
import XCTest

final class YouTubeOutputServiceProcessIntegrationTests: XCTestCase {
  func testEmbeddedServiceBootstrapsAndFinishesOverXPC() throws {
    let completed = expectation(description: "embedded XPC service completed")
    let expectedDate = Date(timeIntervalSince1970: 1_700_000_000.123)

    YouTubeOutputServiceProcessProbe.run { result in
      switch result {
      case .success(let reply):
        XCTAssertEqual(reply.context.revision, 1)
        XCTAssertEqual(reply.nextMediaSegmentNumber, 9)
        XCTAssertEqual(reply.configurationFingerprint, "integration-fingerprint")
        guard let availabilityStartTime = reply.availabilityStartTime else {
          XCTFail("Bootstrap checkpoint omitted availability start time.")
          completed.fulfill()
          return
        }
        XCTAssertEqual(
          availabilityStartTime.timeIntervalSince1970,
          expectedDate.timeIntervalSince1970,
          accuracy: 0.001)
      case .failure(let error):
        XCTFail("Embedded XPC service probe failed: \(error)")
      }
      completed.fulfill()
    }

    wait(for: [completed], timeout: 5)
  }
}
