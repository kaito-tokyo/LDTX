// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingRemuxer: Sendable {
  public init() {}

  public func remux(
    package: RecordingPackage,
    to outputURL: URL,
    replaceExisting: Bool = false
  ) async throws {
    try await remux(
      package: package,
      to: outputURL,
      replaceExisting: replaceExisting,
      canvas: nil
    )
  }

  public func remux(
    package: RecordingPackage,
    to outputURL: URL,
    replaceExisting: Bool = false,
    canvas: RecordingCanvas?
  ) async throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      guard replaceExisting else {
        throw RecordingRemuxerError.outputAlreadyExists(outputURL)
      }
    }

    let temporaryURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
      .appendingPathExtension("mp4")
    defer { try? fileManager.removeItem(at: temporaryURL) }

    let sources = try await makeTrackSources(package: package, canvas: canvas)
    try await writePassthrough(sources: sources, to: temporaryURL)
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: outputURL)
  }

  private func makeTrackSources(
    package: RecordingPackage,
    canvas: RecordingCanvas?
  ) async throws -> [RemuxTrackSource] {
    let selectedMedia: (path: String, url: URL)
    if package.formatVersion == 3 {
      let available = package.availableCanvases
      let selectedCanvas: RecordingCanvas
      if let canvas {
        selectedCanvas = canvas
      } else if available.count == 1, let onlyCanvas = available.first {
        selectedCanvas = onlyCanvas
      } else {
        throw RecordingRemuxerError.canvasSelectionRequired
      }
      guard let media = package.media(for: selectedCanvas) else {
        throw RecordingRemuxerError.canvasUnavailable(selectedCanvas)
      }
      selectedMedia = media
    } else {
      selectedMedia = (package.mainMediaPath, package.mainMediaURL)
    }
    let timeline = try package.manifestURL.map(RecordingDASHTimeline.init(contentsOf:))
    var sources = [
      try await makeTrackSource(
        from: selectedMedia.url,
        mediaPath: selectedMedia.path,
        mediaType: .video,
        isEnabled: true,
        timeline: timeline
      )
    ]
    let audioTracks =
      package.formatVersion == 3
      ? package.audioTracks.filter { track in
        track.mediaURL == selectedMedia.url
          || (track.mediaURL != package.landscapeMediaURL
            && track.mediaURL != package.portraitMediaURL)
      }
      : package.audioTracks
    for (index, audioTrack) in audioTracks.enumerated() {
      let audioTimeline =
        audioTrack.mediaURL == selectedMedia.url ? nil : timeline
      var source = try await makeTrackSource(
        from: audioTrack.mediaURL,
        mediaPath: audioTrack.mediaPath,
        mediaType: .audio,
        isEnabled: index == 0,
        timeline: audioTimeline)
      if audioTrack.mediaURL == selectedMedia.url,
        let start = timeline?.audioPresentationStart(for: audioTrack.mediaPath)
      {
        source.presentationStart = start
      }
      sources.append(source)
    }
    return sources
  }

  private func makeTrackSource(
    from url: URL,
    mediaPath: String,
    mediaType: AVMediaType,
    isEnabled: Bool,
    timeline: RecordingDASHTimeline?
  ) async throws -> RemuxTrackSource {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
      throw RecordingRemuxerError.missingTrack(url, mediaType.rawValue)
    }
    let timeRange = try await track.load(.timeRange)
    let formatDescriptions = try await track.load(.formatDescriptions)
    guard let formatDescription = formatDescriptions.first else {
      throw RecordingRemuxerError.missingFormatDescription(url, mediaType.rawValue)
    }
    return RemuxTrackSource(
      asset: asset,
      track: track,
      mediaType: mediaType,
      formatDescription: formatDescription,
      presentationStart: timeline?.presentationStart(for: mediaPath) ?? timeRange.start,
      sourceStart: timeRange.start,
      isEnabled: isEnabled
    )
  }

  private func writePassthrough(sources: [RemuxTrackSource], to outputURL: URL) async throws {
    let movie = try AVMutableMovie(settingsFrom: nil, options: nil)
    movie.timescale = 1_000_000_000
    movie.defaultMediaDataStorage = AVMediaDataStorage(url: outputURL)
    for source in sources {
      guard
        let destination = movie.addMutableTrack(
          withMediaType: source.mediaType, copySettingsFrom: source.track, options: nil)
      else { throw RecordingRemuxerError.cannotCreateWriterInput(source.mediaType.rawValue) }
      destination.isEnabled = source.isEnabled
      let range = try await source.track.load(.timeRange)
      try destination.insertTimeRange(
        range, of: source.track, at: source.presentationStart, copySampleData: true)
    }
    try movie.writeHeader(to: outputURL, fileType: .mp4, options: .addMovieHeaderToDestination)
  }

}

private struct RemuxTrackSource: @unchecked Sendable {
  var asset: AVAsset
  var track: AVAssetTrack
  var mediaType: AVMediaType
  var formatDescription: CMFormatDescription
  var presentationStart: CMTime
  var sourceStart: CMTime
  var isEnabled: Bool
}
