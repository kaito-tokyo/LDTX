// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation
@testable import LDTXMP4
import Testing
import UniformTypeIdentifiers
import os

extension OutputTestSuite {
  @Suite
  struct AVAssetWriterSegmentDelegateUnitTestSuite {
    @Test("Segments are routed to the handler of their writer until it is unregistered")
    func segmentsAreRoutedToTheHandlerOfTheirWriterUntilItIsUnregistered() {
      let delegate = AVAssetWriterSegmentDelegate()
      let first = AVAssetWriter(contentType: .mpeg4Movie)
      let second = AVAssetWriter(contentType: .mpeg4Movie)
      let received = OSAllocatedUnfairLock<[String]>(initialState: [])
      delegate.register(first) { data, _, _ in
        received.withLock { $0.append("first:\(data.count)") }
      }
      delegate.register(second) { data, _, _ in
        received.withLock { $0.append("second:\(data.count)") }
      }

      delegate.assetWriter(
        first, didOutputSegmentData: Data(count: 1), segmentType: .initialization,
        segmentReport: nil)
      delegate.assetWriter(
        second, didOutputSegmentData: Data(count: 2), segmentType: .separable,
        segmentReport: nil)
      delegate.unregister(first)
      delegate.assetWriter(
        first, didOutputSegmentData: Data(count: 3), segmentType: .separable,
        segmentReport: nil)

      #expect(received.withLock { $0 } == ["first:1", "second:2"])
    }

    @Test("Concurrent registration and delivery keep each writer's handler")
    func concurrentRegistrationAndDeliveryKeepEachWritersHandler() {
      let delegate = AVAssetWriterSegmentDelegate()
      let writerCount = 16
      let counts = OSAllocatedUnfairLock(initialState: Array(repeating: 0, count: writerCount))

      DispatchQueue.concurrentPerform(iterations: writerCount) { index in
        // Each writer stays alive until it is unregistered, so its identifier is not reused.
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        delegate.register(writer) { _, _, _ in counts.withLock { $0[index] += 1 } }
        for _ in 0..<10 {
          delegate.assetWriter(
            writer, didOutputSegmentData: Data(), segmentType: .separable, segmentReport: nil)
        }
        delegate.unregister(writer)
      }

      #expect(counts.withLock { $0 } == Array(repeating: 10, count: writerCount))
    }
  }
}
