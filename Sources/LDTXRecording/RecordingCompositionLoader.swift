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
    try await insertGenerationTracks(
      urls: package.mainMediaURLs, paths: package.mainMediaPaths,
      mediaType: .video, isEnabled: true, timeline: timeline, into: composition)
    try await insertGenerationTracks(
      urls: package.mainMediaURLs, paths: package.mainMediaPaths,
      mediaType: .audio, isEnabled: true, timeline: timeline, into: composition)
    for audioTrack in package.audioTracks {
      let isEnabled = enabledAudioTrackIdentifier == audioTrack.identifier
      try await insertGenerationTracks(
        urls: audioTrack.mediaURLs,
        paths: audioTrack.mediaPaths,
        mediaType: .audio,
        isEnabled: isEnabled,
        timeline: timeline,
        into: composition
      )
    }
    return composition
  }

  private func insertGenerationTracks(
    urls: [URL],
    paths: [String],
    mediaType: AVMediaType,
    isEnabled: Bool,
    timeline: RecordingDASHTimeline?,
    into composition: AVMutableComposition
  ) async throws {
    guard let destinationTrack = composition.addMutableTrack(
      withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw RecordingRemuxerError.cannotCreateCompositionTrack(mediaType.rawValue)
    }
    for (url, path) in zip(urls, paths) {
      try await insertTrack(from: url, mediaPath: path, mediaType: mediaType, timeline: timeline, into: destinationTrack)
    }
    destinationTrack.isEnabled = isEnabled
  }

  private func insertTrack(
    from url: URL,
    mediaPath: String,
    mediaType: AVMediaType,
    timeline: RecordingDASHTimeline?,
    into destinationTrack: AVMutableCompositionTrack
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first else {
      throw RecordingRemuxerError.missingTrack(url, mediaType.rawValue)
    }
    let timeRange = try await sourceTrack.load(.timeRange)
    let presentationStart = timeline?.presentationStart(for: mediaPath) ?? timeRange.start
    try destinationTrack.insertTimeRange(timeRange, of: sourceTrack, at: presentationStart)
    if mediaType == .video {
      destinationTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
    }
  }
}
