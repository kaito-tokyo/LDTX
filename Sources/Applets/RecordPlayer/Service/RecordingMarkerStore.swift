// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingMarker: Equatable, Sendable {
  public let time: CMTime
  public let timecode: String
  public let note: String
  public let fileURL: URL

  public init(time: CMTime, timecode: String, note: String, fileURL: URL) {
    self.time = time
    self.timecode = timecode
    self.note = note
    self.fileURL = fileURL
  }
}

public struct RecordingMarkerStore: Sendable {
  public static let directoryName = "Markers"

  public let recordingDirectoryURL: URL

  public init(recordingDirectoryURL: URL) {
    self.recordingDirectoryURL = recordingDirectoryURL.standardizedFileURL
  }

  public func createMarker(at time: CMTime, note: String) throws -> URL {
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecordingMarkerError.emptyNote
    }

    let fileName = try Self.fileName(for: time)
    let fileManager = FileManager.default
    let directoryURL = recordingDirectoryURL.appendingPathComponent(
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

  public func markers() throws -> [RecordingMarker] {
    let fileManager = FileManager.default
    let directoryURL = recordingDirectoryURL.appendingPathComponent(
      Self.directoryName,
      isDirectory: true
    )
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
      return []
    }
    let directoryValues = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard isDirectory.boolValue, directoryValues.isSymbolicLink != true else {
      throw RecordingMarkerError.invalidMarkersDirectory
    }

    let fileURLs = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    var markers: [RecordingMarker] = []
    for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "txt" {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let time = Self.time(fromMarkerFileName: fileURL.lastPathComponent)
      else { continue }

      guard var note = try? String(contentsOf: fileURL, encoding: .utf8),
        let timecode = try? Self.displayTimecode(for: time)
      else { continue }
      while note.last?.isNewline == true {
        note.removeLast()
      }
      markers.append(
        RecordingMarker(
          time: time,
          timecode: timecode,
          note: note,
          fileURL: fileURL
        )
      )
    }
    return markers.sorted {
      let comparison = CMTimeCompare($0.time, $1.time)
      return comparison == 0
        ? $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent
        : comparison < 0
    }
  }

  public func deleteMarker(_ marker: RecordingMarker) throws {
    let markersDirectoryURL = recordingDirectoryURL.appendingPathComponent(
      Self.directoryName,
      isDirectory: true
    ).standardizedFileURL
    let markerURL = marker.fileURL.standardizedFileURL
    guard markerURL.deletingLastPathComponent() == markersDirectoryURL,
      markerURL.pathExtension.lowercased() == "txt"
    else {
      throw RecordingMarkerError.invalidMarkerFile
    }

    let values = try markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw RecordingMarkerError.invalidMarkerFile
    }
    try FileManager.default.removeItem(at: markerURL)
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

  private static func time(fromMarkerFileName fileName: String) -> CMTime? {
    let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    let clockComponents = stem.split(separator: "-", omittingEmptySubsequences: false)
    guard clockComponents.count == 3,
      let hours = Int64(clockComponents[0]),
      let minutes = Int64(clockComponents[1]),
      (0..<60).contains(minutes)
    else { return nil }

    let secondComponents = clockComponents[2].split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard secondComponents.count == 2,
      secondComponents[1].count == 3,
      let seconds = Int64(secondComponents[0]),
      let milliseconds = Int64(secondComponents[1]),
      (0..<60).contains(seconds),
      (0..<1_000).contains(milliseconds)
    else { return nil }

    let (hourMilliseconds, hoursOverflowed) = hours.multipliedReportingOverflow(by: 3_600_000)
    let (minuteMilliseconds, minutesOverflowed) = minutes.multipliedReportingOverflow(by: 60_000)
    let (secondMilliseconds, secondsOverflowed) = seconds.multipliedReportingOverflow(by: 1_000)
    let (withMinutes, minutesAdditionOverflowed) = hourMilliseconds.addingReportingOverflow(
      minuteMilliseconds
    )
    let (withSeconds, secondsAdditionOverflowed) = withMinutes.addingReportingOverflow(
      secondMilliseconds
    )
    let (totalMilliseconds, millisecondsAdditionOverflowed) = withSeconds.addingReportingOverflow(
      milliseconds
    )
    guard !hoursOverflowed, !minutesOverflowed, !secondsOverflowed,
      !minutesAdditionOverflowed, !secondsAdditionOverflowed,
      !millisecondsAdditionOverflowed
    else { return nil }
    return CMTime(value: totalMilliseconds, timescale: 1_000)
  }
}

public enum RecordingMarkerError: Error, LocalizedError, Equatable, Sendable {
  case invalidTime
  case emptyNote
  case invalidMarkersDirectory
  case invalidMarkerFile
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
    case .invalidMarkerFile:
      "The selected marker is not a valid marker file."
    case .markerAlreadyExists(let fileName):
      "A marker already exists at this time: \(fileName)"
    case .cannotEncodeNote:
      "The marker note could not be encoded as UTF-8."
    }
  }
}
