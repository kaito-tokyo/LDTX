// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXRecordBundleFormat

public struct RecordingDASHTimeline {
  public static let audioStartScheme = RecordingDASHManifestTimeline.audioStartScheme
  private let timeline: RecordingDASHManifestTimeline

  public init(contentsOf manifestURL: URL) throws {
    do {
      timeline = try RecordingDASHManifestTimeline(contentsOf: manifestURL)
    } catch RecordingDASHManifestError.invalidManifest(let message) {
      throw RecordingRemuxerError.invalidManifest(message)
    }
  }

  public func presentationStart(for mediaPath: String) -> CMTime? {
    timeline.presentationStart(for: mediaPath).map { CMTime(value: $0, timescale: 1_000_000_000) }
  }

  public func audioPresentationStart(for mediaPath: String) -> CMTime? {
    timeline.audioPresentationStart(for: mediaPath).map {
      CMTime(value: $0, timescale: 1_000_000_000)
    }
  }
}
