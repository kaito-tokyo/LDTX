// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingMarker: Equatable, Sendable {
  public let time: CMTime
  public let timecode: String
  public let note: String
  public let fileName: String

  public init(time: CMTime, timecode: String, note: String, fileName: String) {
    self.time = time
    self.timecode = timecode
    self.note = note
    self.fileName = fileName
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

      var note = try String(contentsOf: fileURL, encoding: .utf8)
      let timecode = try Self.displayTimecode(for: time)
      while note.last?.isNewline == true {
        note.removeLast()
      }
      markers.append(
        RecordingMarker(
          time: time,
          timecode: timecode,
          note: note,
          fileName: fileURL.lastPathComponent
        )
      )
    }
    return markers.sorted {
      let comparison = CMTimeCompare($0.time, $1.time)
      return comparison == 0
        ? $0.fileName < $1.fileName
        : comparison < 0
    }
  }

  public func deleteMarker(
    _ marker: RecordingMarker, filePresenter: (any NSFilePresenter)? = nil
  ) throws {
    try coordinatedWrite(filePresenter: filePresenter) { store in
      try Self.validateFileName(marker.fileName)
      let directory = try store.markerDirectory(create: false)
      let url = directory.appendingPathComponent(marker.fileName)
      do {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw RecordingMarkerError.invalidMarkerFile
        }
        try FileManager.default.removeItem(at: url)
      } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
      {
        // Unsaved or already deleted markers have no file to remove.
      }
    }
  }

  /// Adds or overwrites individual files, then returns the disk contents under the same coordination.
  @discardableResult
  public func save(
    _ snapshot: [RecordingMarker], filePresenter: (any NSFilePresenter)? = nil
  ) throws -> [RecordingMarker] {
    try coordinatedWrite(filePresenter: filePresenter) { store in
      let directory = try store.markerDirectory(create: true)
      let manager = FileManager.default
      var names: [String: String] = [:]
      for url in try manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          url.pathExtension.lowercased() == "txt",
          let time = Self.time(fromMarkerFileName: url.lastPathComponent)
        else { continue }
        let key = try Self.fileName(for: time)
        if names[key] == nil { names[key] = url.lastPathComponent }
      }
      var writtenTimes = Set<String>()
      for marker in snapshot.sorted(by: { $0.fileName < $1.fileName }) {
        try Self.validateFileName(marker.fileName)
        let key = try Self.fileName(for: marker.time)
        guard let storedTime = Self.time(fromMarkerFileName: marker.fileName),
          try Self.fileName(for: storedTime) == key
        else { throw RecordingMarkerError.invalidMarkerFile }
        guard writtenTimes.insert(key).inserted else { continue }
        let name = names[key] ?? marker.fileName
        names[key] = name
        let target = directory.appendingPathComponent(name)
        if manager.fileExists(atPath: target.path) {
          let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RecordingMarkerError.invalidMarkerFile
          }
        }
        let contents = marker.note.hasSuffix("\n") ? marker.note : marker.note + "\n"
        try Data(contents.utf8).write(to: target, options: .atomic)
      }
      return try store.markers()
    }
  }

  private func markerDirectory(create: Bool) throws -> URL {
    let directory = recordingDirectoryURL.appendingPathComponent(
      Self.directoryName, isDirectory: true)
    if FileManager.default.fileExists(atPath: directory.path) {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw RecordingMarkerError.invalidMarkersDirectory
      }
    } else if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    return directory
  }

  private func coordinatedWrite<T>(
    filePresenter: (any NSFilePresenter)?, _ operation: (Self) throws -> T
  ) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: filePresenter)
    var coordinationError: NSError?
    var result: Result<T, Error>?
    coordinator.coordinate(
      writingItemAt: recordingDirectoryURL, options: [], error: &coordinationError
    ) { url in
      result = Result {
        guard
          !FileManager.default.fileExists(atPath: url.appendingPathComponent(".shield.json").path)
        else {
          throw RecordingMarkerError.recordingInProgress
        }
        return try operation(Self(recordingDirectoryURL: url))
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileWriteUnknown) }
    return try result.get()
  }

  private static func validateFileName(_ name: String) throws {
    guard !name.isEmpty, !name.contains("/"), !name.contains("\u{0}"),
      name != ".", name != "..", name.lowercased().hasSuffix(".txt"),
      time(fromMarkerFileName: name) != nil
    else { throw RecordingMarkerError.invalidMarkerFile }
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
  case recordingInProgress
  case unsupportedOperation
  case invalidTime
  case emptyNote
  case invalidMarkersDirectory
  case invalidMarkerFile
  case markerAlreadyExists(String)
  case cannotEncodeNote

  public var errorDescription: String? {
    switch self {
    case .recordingInProgress:
      "Markers cannot be saved while the recording is being written."
    case .unsupportedOperation:
      "Recording documents support saving markers in the original recording only."
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
