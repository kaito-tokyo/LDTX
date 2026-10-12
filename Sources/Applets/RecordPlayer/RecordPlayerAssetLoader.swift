// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import LDTXRecordBundleFormat
import LDTXRecording

extension LDTXRecordPlayerModel {
  static func loadAsset(
    recordingURL: URL, canvas: RecordingCanvas?
  ) async throws -> AVAsset {
    let package = try RecordingPackage(contentsOf: recordingURL)
    let media = canvas.flatMap(package.media(for:))
    let mediaPath = media?.path ?? package.mainMediaPath
    let asset = AVURLAsset(url: media?.url ?? package.mainMediaURL)
    let timeline = try RecordingDASHTimeline(
      contentsOf: recordingURL.appendingPathComponent("manifest.mpd")
    )
    let composition = AVMutableComposition()
    let presentationStart = timeline.presentationStart(for: mediaPath)
    let audioStart = timeline.audioPresentationStart(for: mediaPath) ?? presentationStart

    try await insertFirstTrack(
      from: asset,
      mediaType: .video,
      at: presentationStart,
      into: composition
    )
    try await insertFirstTrack(
      from: asset,
      mediaType: .audio,
      at: audioStart,
      into: composition
    )
    return composition
  }

  private static func insertFirstTrack(
    from asset: AVAsset,
    mediaType: AVMediaType,
    at presentationStart: CMTime?,
    into composition: AVMutableComposition
  ) async throws {
    guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first,
      let destinationTrack = composition.addMutableTrack(
        withMediaType: mediaType,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let timeRange = try await sourceTrack.load(.timeRange)
    try destinationTrack.insertTimeRange(
      timeRange,
      of: sourceTrack,
      at: presentationStart ?? timeRange.start
    )
    if mediaType == .video {
      destinationTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
    }
  }

}
