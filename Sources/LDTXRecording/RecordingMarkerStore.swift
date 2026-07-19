// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingMarkerStore: Sendable {
  public static let directoryName = "Markers"

  public let package: RecordingPackage

  public init(package: RecordingPackage) {
    self.package = package
  }

  public func createMarker(at time: CMTime, note: String) throws -> URL {
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecordingMarkerError.emptyNote
    }

    let fileName = try Self.fileName(for: time)
    let fileManager = FileManager.default
    let directoryURL = package.directoryURL.appendingPathComponent(
      Self.directoryName,
      isDirectory: true
    )
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
      let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isSymbolicLink != true else {
        throw RecordingMarkerError.invalidMarkersDirectory
      }
    } else {
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    }

    let markerURL = directoryURL.appendingPathComponent(fileName)
    guard !fileManager.fileExists(atPath: markerURL.path) else {
      throw RecordingMarkerError.markerAlreadyExists(fileName)
    }

    let contents = note.hasSuffix("\n") ? note : note + "\n"
    guard let data = contents.data(using: .utf8) else {
      throw RecordingMarkerError.cannotEncodeNote
    }
    try data.write(to: markerURL, options: .withoutOverwriting)
    return markerURL
  }

  public static func fileName(for time: CMTime) throws -> String {
    "\(try timecode(for: time, separator: "-" )).txt"
  }

  public static func displayTimecode(for time: CMTime) throws -> String {
    try timecode(for: time, separator: ":")
  }

  private static func timecode(for time: CMTime, separator: String) throws -> String {
    guard time.isValid, time.isNumeric, !time.isIndefinite else {
      throw RecordingMarkerError.invalidTime
    }
    let milliseconds = CMTimeConvertScale(time, timescale: 1_000, method: .roundHalfAwayFromZero)
      .value
    guard milliseconds >= 0 else {
      throw RecordingMarkerError.invalidTime
    }

    let hours = milliseconds / 3_600_000
    let minutes = (milliseconds / 60_000) % 60
    let seconds = (milliseconds / 1_000) % 60
    let fraction = milliseconds % 1_000
    let clock = [hours, minutes, seconds]
      .map { String(format: "%02lld", $0) }
      .joined(separator: separator)
    return "\(clock).\(String(format: "%03lld", fraction))"
  }
}

public enum RecordingMarkerError: Error, LocalizedError, Equatable, Sendable {
  case invalidTime
  case emptyNote
  case invalidMarkersDirectory
  case markerAlreadyExists(String)
  case cannotEncodeNote

  public var errorDescription: String? {
    switch self {
    case .invalidTime:
      "The current playback time cannot be used for a marker."
    case .emptyNote:
      "Enter a note for the marker."
    case .invalidMarkersDirectory:
      "The recording's Markers item is not a writable directory."
    case .markerAlreadyExists(let fileName):
      "A marker already exists at this time: \(fileName)"
    case .cannotEncodeNote:
      "The marker note could not be encoded as UTF-8."
    }
  }
}
