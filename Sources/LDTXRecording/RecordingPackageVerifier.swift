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
    var warnings: [String] = []
    if package.audioTracks.isEmpty {
      if strict { throw RecordingPackageVerificationError.missingAudioTracks }
      warnings.append("Recording package contains no audio tracks; remuxing video only.")
    }

    try await verifyTrack(
      at: package.mainMediaURL,
      path: package.mainMediaPath,
      mediaType: .video
    )
    for audioTrack in package.audioTracks {
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
    for path in [package.mainMediaPath] + package.audioTracks.map(\.mediaPath) {
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
  case missingAudioTracks
  case missingManifest
  case invalidMediaFile(String)
  case missingMediaTrack(String, String)
  case missingFormatDescription(String, String)
  case emptyMediaTrack(String, String)
  case missingManifestRepresentation(String)

  public var errorDescription: String? {
    switch self {
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
