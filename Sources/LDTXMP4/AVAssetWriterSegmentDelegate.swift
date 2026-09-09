// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

/// Process-lifetime delegate for segmented asset writers.
///
/// `AVAssetWriter` retains its delegate weakly and may deliver segment
/// notifications asynchronously. Keeping the weakly referenced delegate alive
/// independently of an individual writer prevents deferred CoreMedia
/// notifications from targeting a deallocated writer owner.
final class AVAssetWriterSegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
  typealias Handler = @Sendable (Data, AVAssetSegmentType, AVAssetSegmentReport?) -> Void

  static let shared = AVAssetWriterSegmentDelegate()

  private let lock = NSLock()
  private var handlers: [ObjectIdentifier: Handler] = [:]

  func register(_ writer: AVAssetWriter, handler: @escaping Handler) {
    lock.withLock { handlers[ObjectIdentifier(writer)] = handler }
  }

  func unregister(_ writer: AVAssetWriter) {
    _ = lock.withLock { handlers.removeValue(forKey: ObjectIdentifier(writer)) }
  }

  func assetWriter(
    _ writer: AVAssetWriter,
    didOutputSegmentData segmentData: Data,
    segmentType: AVAssetSegmentType,
    segmentReport: AVAssetSegmentReport?
  ) {
    let handler = lock.withLock { handlers[ObjectIdentifier(writer)] }
    handler?(segmentData, segmentType, segmentReport)
  }
}
