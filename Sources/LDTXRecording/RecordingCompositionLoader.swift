// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingCompositionLoader: Sendable {
  public init() {}

  @MainActor
  public func load(
    package: RecordingPackage,
    enabledAudioTrackIdentifier: String? = nil
  ) async throws -> AVMutableComposition {
    let composition = AVMutableComposition()
    let timeline = try package.manifestURL.map(RecordingDASHTimeline.init(contentsOf:))
    try await insertFirstTrack(
      from: package.mainMediaURL,
      mediaPath: package.mainMediaPath,
      mediaType: .video,
      isEnabled: true,
      timeline: timeline,
      into: composition
    )
    for (index, audioTrack) in package.audioTracks.enumerated() {
      let audioTimeline =
        audioTrack.mediaURL == package.mainMediaURL ? nil : timeline
      let isEnabled =
        enabledAudioTrackIdentifier.map {
          $0 == audioTrack.identifier
        } ?? (index == 0)
      try await insertFirstTrack(
        from: audioTrack.mediaURL,
        mediaPath: audioTrack.mediaPath,
        mediaType: .audio,
        isEnabled: isEnabled,
        timeline: audioTimeline,
        into: composition
      )
    }
    return composition
  }

  private func insertFirstTrack(
    from url: URL,
    mediaPath: String,
    mediaType: AVMediaType,
    isEnabled: Bool,
    timeline: RecordingDASHTimeline?,
    into composition: AVMutableComposition
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first else {
      throw RecordingRemuxerError.missingTrack(url, mediaType.rawValue)
    }
    let timeRange = try await sourceTrack.load(.timeRange)
    guard
      let destinationTrack = composition.addMutableTrack(
        withMediaType: mediaType,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw RecordingRemuxerError.cannotCreateCompositionTrack(mediaType.rawValue)
    }
    let presentationStart = timeline?.presentationStart(for: mediaPath) ?? timeRange.start
    try destinationTrack.insertTimeRange(timeRange, of: sourceTrack, at: presentationStart)
    if mediaType == .video {
      destinationTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
    }
    destinationTrack.isEnabled = isEnabled
  }
}
