// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

protocol LocalOutputService {
  var defaultBaseDirectory: URL { get }

  func makeMP4OutputURL(baseDirectory: URL) -> URL
  func makeDASHOutputDirectory(baseDirectory: URL) -> URL
  func prepareMP4OutputDirectory(for outputURL: URL) throws
  func validateWritableBaseDirectory(_ directory: URL) throws
  func prepareDASHOutputDirectory(
    _ outputDirectory: URL,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    videoBitRate: Int
  ) throws
}

struct DefaultLocalOutputService: LocalOutputService {
  private let fileManager: FileManager

  init(fileManager: FileManager) {
    self.fileManager = fileManager
  }

  var defaultBaseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Movies", isDirectory: true)
  }

  func makeMP4OutputURL(baseDirectory: URL) -> URL {
    baseDirectory
      .appendingPathComponent("LDTX-\(timestamp())")
      .appendingPathExtension("mp4")
  }

  func makeDASHOutputDirectory(baseDirectory: URL) -> URL {
    baseDirectory
      .appendingPathComponent("LDTX-DASH-\(timestamp())", isDirectory: true)
  }

  func prepareMP4OutputDirectory(for outputURL: URL) throws {
    try fileManager.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  func validateWritableBaseDirectory(_ directory: URL) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw LocalOutputServiceError.outputDirectoryUnavailable(directory.path)
    }
    let probeURL = directory.appendingPathComponent(
      ".ldtx-write-probe-\(UUID().uuidString)", isDirectory: false)
    do {
      try Data().write(to: probeURL, options: .withoutOverwriting)
      try fileManager.removeItem(at: probeURL)
    } catch {
      try? fileManager.removeItem(at: probeURL)
      throw LocalOutputServiceError.outputDirectoryNotWritable(
        path: directory.path, underlyingDescription: error.localizedDescription)
    }
  }

  func prepareDASHOutputDirectory(
    _ outputDirectory: URL,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    videoBitRate: Int
  ) throws {
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try writeDASHSessionMarker(
      outputDirectory: outputDirectory,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      frameRate: frameRate,
      videoBitRate: videoBitRate
    )
  }

  private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private func writeDASHSessionMarker(
    outputDirectory: URL,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    videoBitRate: Int
  ) throws {
    let text = [
      "LDTX Local DASH capture started.",
      "createdAt=\(ISO8601DateFormatter().string(from: Date()))",
      "width=\(targetWidth)",
      "height=\(targetHeight)",
      "frameRate=\(frameRate)",
      "videoBitRate=\(videoBitRate)",
      "note=init.mp4, manifest.mpd, and media*.mp4 are written after AVAssetWriter emits the first fragmented MP4 segment.",
    ].joined(separator: "\n")
    try text.write(
      to: outputDirectory.appendingPathComponent("capture-started.txt"),
      atomically: true,
      encoding: .utf8
    )
  }
}

enum LocalOutputServiceError: LocalizedError {
  case outputDirectoryUnavailable(String)
  case outputDirectoryNotWritable(path: String, underlyingDescription: String)

  var errorDescription: String? {
    switch self {
    case .outputDirectoryUnavailable(let path):
      "The output folder is unavailable: \(path)"
    case .outputDirectoryNotWritable(let path, let underlyingDescription):
      "The output folder is not writable: \(path) (\(underlyingDescription))"
    }
  }
}
