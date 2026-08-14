// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingPackageVerifier: Sendable {
  public init() {}

  public func verify(_ package: RecordingPackage) async throws {
    _ = try await verify(package, strict: true)
  }

  @discardableResult
  public func verify(_ package: RecordingPackage, strict: Bool) async throws -> [String] {
    try await verify(package, strict: strict, canvas: nil)
  }

  public func verify(
    _ package: RecordingPackage,
    strict: Bool,
    canvas: RecordingCanvas?
  ) async throws -> [String] {
    var warnings: [String] = []
    let audioTracks: [RecordingAudioTrack]
    if package.formatVersion >= 3, let canvas {
      let excludedMixID = canvas == .landscape ? "portrait-mix" : "landscape-mix"
      audioTracks = package.audioTracks.filter { $0.identifier != excludedMixID }
    } else {
      audioTracks = package.audioTracks
    }
    if audioTracks.isEmpty {
      if strict { throw RecordingPackageVerificationError.missingAudioTracks }
      warnings.append("Recording package contains no audio tracks; remuxing video only.")
    }

    let videoTracks: [(url: URL, path: String)]
    if package.formatVersion >= 3, let canvas {
      guard let media = package.media(for: canvas) else {
        throw RecordingPackageVerificationError.missingCanvas(canvas)
      }
      videoTracks = [(media.url, media.path)]
    } else if package.formatVersion >= 3 {
      videoTracks = package.availableCanvases.compactMap { canvas in
        package.media(for: canvas).map { (url: $0.url, path: $0.path) }
      }
    } else {
      videoTracks = [(package.mainMediaURL, package.mainMediaPath)]
    }
    for videoTrack in videoTracks {
      try await verifyTrack(
        at: videoTrack.url,
        path: videoTrack.path,
        mediaType: .video
      )
    }
    for audioTrack in audioTracks {
      try await verifyTrack(
        at: audioTrack.mediaURL,
        path: audioTrack.mediaPath,
        mediaType: .audio
      )
    }

    guard let manifestURL = package.manifestURL else {
      if strict { throw RecordingPackageVerificationError.missingManifest }
      warnings.append(
        "Recording package contains no MPEG-DASH manifest; using native media timestamps."
      )
      return warnings
    }
    let timeline = try RecordingDASHTimeline(contentsOf: manifestURL)
    for path in videoTracks.map(\.path) + audioTracks.map(\.mediaPath) {
      guard timeline.presentationStart(for: path) != nil else {
        if strict {
          throw RecordingPackageVerificationError.missingManifestRepresentation(path)
        }
        warnings.append(
          "Recording manifest contains no Representation for \(path); using its native media timestamp."
        )
        continue
      }
    }
    return warnings
  }

  private func verifyTrack(
    at url: URL,
    path: String,
    mediaType: AVMediaType
  ) async throws {
    let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard resourceValues.isRegularFile == true, (resourceValues.fileSize ?? 0) > 0 else {
      throw RecordingPackageVerificationError.invalidMediaFile(path)
    }
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
      throw RecordingPackageVerificationError.missingMediaTrack(path, mediaType.rawValue)
    }
    let formatDescriptions = try await track.load(.formatDescriptions)
    guard !formatDescriptions.isEmpty else {
      throw RecordingPackageVerificationError.missingFormatDescription(
        path, mediaType.rawValue)
    }
    let timeRange = try await track.load(.timeRange)
    guard timeRange.duration.isNumeric, timeRange.duration > .zero else {
      throw RecordingPackageVerificationError.emptyMediaTrack(path, mediaType.rawValue)
    }
  }
}

public enum RecordingPackageVerificationError: Error, LocalizedError, Equatable, Sendable {
  case missingCanvas(RecordingCanvas)
  case missingAudioTracks
  case missingManifest
  case invalidMediaFile(String)
  case missingMediaTrack(String, String)
  case missingFormatDescription(String, String)
  case emptyMediaTrack(String, String)
  case missingManifestRepresentation(String)

  public var errorDescription: String? {
    switch self {
    case .missingCanvas(let canvas):
      "Recording package contains no \(canvas.rawValue) Canvas media."
    case .missingAudioTracks:
      "Recording package contains no audio tracks."
    case .missingManifest:
      "Recording package contains no MPEG-DASH manifest."
    case .invalidMediaFile(let path):
      "Recording media file is not a non-empty regular file: \(path)"
    case .missingMediaTrack(let path, let mediaType):
      "Recording media file contains no \(mediaType) track: \(path)"
    case .missingFormatDescription(let path, let mediaType):
      "Recording \(mediaType) track has no format description: \(path)"
    case .emptyMediaTrack(let path, let mediaType):
      "Recording \(mediaType) track is empty: \(path)"
    case .missingManifestRepresentation(let path):
      "Recording manifest contains no Representation for: \(path)"
    }
  }
}
