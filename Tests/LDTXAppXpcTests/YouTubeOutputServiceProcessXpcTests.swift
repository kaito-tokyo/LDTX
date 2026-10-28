// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletService
import Testing

@Suite struct YouTubeOutputServiceProcessXpcTests {
  @Test func lub1040_EmbeddedServiceBootstrapsAndFinishesOverXPC() async throws {
    let expectedDate = Date(timeIntervalSince1970: 1_700_000_000.123)
    let results = AsyncStream<Result<YouTubeOutputServiceProcessProbeResult, any Error>?> {
      continuation in
      YouTubeOutputServiceProcessProbe.run { result in
        continuation.yield(result)
        continuation.finish()
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        continuation.yield(nil)
        continuation.finish()
      }
    }
    var iterator = results.makeAsyncIterator()
    let result = try #require(await iterator.next() ?? nil, "Embedded XPC service timed out.")
    let reply = try result.get()
    #expect(reply.context.revision == 1)
    #expect(reply.nextMediaSegmentNumber == 9)
    #expect(reply.configurationFingerprint == "integration-fingerprint")
    let availabilityStartTime = try #require(reply.availabilityStartTime)
    #expect(
      abs(availabilityStartTime.timeIntervalSince1970 - expectedDate.timeIntervalSince1970) <= 0.001
    )
  }
}
