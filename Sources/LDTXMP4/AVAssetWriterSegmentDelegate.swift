// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Process-lifetime delegate for segmented asset writers.
///
/// `AVAssetWriter` retains its delegate weakly and may deliver segment
/// notifications asynchronously. Keeping the weakly referenced delegate alive
/// independently of an individual writer prevents deferred CoreMedia
/// notifications from targeting a deallocated writer owner.
final class AVAssetWriterSegmentDelegate: NSObject, AVAssetWriterDelegate, Sendable {
  typealias Handler = @Sendable (Data, AVAssetSegmentType, AVAssetSegmentReport?) -> Void

  static let shared = AVAssetWriterSegmentDelegate()

  private let handlers = Mutex<[ObjectIdentifier: Handler]>([:])

  func register(_ writer: AVAssetWriter, handler: @escaping Handler) {
    handlers.withLock { $0[ObjectIdentifier(writer)] = handler }
  }

  func unregister(_ writer: AVAssetWriter) {
    _ = handlers.withLock { $0.removeValue(forKey: ObjectIdentifier(writer)) }
  }

  func assetWriter(
    _ writer: AVAssetWriter,
    didOutputSegmentData segmentData: Data,
    segmentType: AVAssetSegmentType,
    segmentReport: AVAssetSegmentReport?
  ) {
    let handler = handlers.withLock { $0[ObjectIdentifier(writer)] }
    handler?(segmentData, segmentType, segmentReport)
  }
}
