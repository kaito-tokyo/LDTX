// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

enum RecordingShieldEntryKind: Sendable { case regular, directory, unsafe }
enum RecordingShieldEntriesError: Error {
  case invalidPath(String)
  case ioFailure
}
struct RecordingShieldEntry: Sendable {
  var path: String
  var kind: RecordingShieldEntryKind
  var sha256: String?
}

enum RecordingShieldEntries {
  static func collect(at root: URL) throws -> [RecordingShieldEntry] {
    let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    defer { close(rootDescriptor) }
    var rootStat = stat()
    guard fstat(rootDescriptor, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
      throw CocoaError(.fileReadNoSuchFile)
    }

    return try collect(directoryDescriptor: rootDescriptor)
  }

  static func collect(
    directoryDescriptor: Int32,
    shouldHashRegularFile: (String) -> Bool = { _ in true }
  ) throws -> [RecordingShieldEntry] {
    var result: [RecordingShieldEntry] = []
    try visit(
      directoryDescriptor: directoryDescriptor,
      relativeDirectory: "",
      directoryDepth: 0,
      shouldHashRegularFile: shouldHashRegularFile,
      result: &result
    )
    return result
  }

  private static func visit(
    directoryDescriptor: Int32,
    relativeDirectory: String,
    directoryDepth: Int,
    shouldHashRegularFile: (String) -> Bool,
    result: inout [RecordingShieldEntry]
  ) throws {
    let enumerationDescriptor = dup(directoryDescriptor)
    guard enumerationDescriptor >= 0, let directory = fdopendir(enumerationDescriptor) else {
      if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
      throw CocoaError(.fileReadUnknown)
    }
    defer { closedir(directory) }

    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw RecordingShieldEntriesError.ioFailure }
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else { throw RecordingShieldEntriesError.invalidPath(relativeDirectory) }
      guard name != ".", name != ".." else { continue }
      let path = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
      var entryStat = stat()
      guard fstatat(directoryDescriptor, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CocoaError(.fileReadUnknown)
      }
      switch entryStat.st_mode & S_IFMT {
      case S_IFREG:
        let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
          if isUnsafeReplacementError(errno) {
            result.append(.init(path: path, kind: .unsafe, sha256: nil))
            continue
          }
          throw RecordingShieldEntriesError.ioFailure
        }
        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0, (openedStat.st_mode & S_IFMT) == S_IFREG else {
          close(descriptor)
          result.append(.init(path: path, kind: .unsafe, sha256: nil))
          continue
        }
        let sha256: String?
        if shouldHashRegularFile(path) {
          sha256 = try RecordingShieldHash.sha256(fileDescriptor: descriptor)
        } else {
          close(descriptor)
          sha256 = nil
        }
        result.append(.init(path: path, kind: .regular, sha256: sha256))
      case S_IFDIR:
        let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
          if isUnsafeReplacementError(errno) {
            result.append(.init(path: path, kind: .unsafe, sha256: nil))
            continue
          }
          throw RecordingShieldEntriesError.ioFailure
        }
        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0, (openedStat.st_mode & S_IFMT) == S_IFDIR else {
          close(descriptor)
          result.append(.init(path: path, kind: .unsafe, sha256: nil))
          continue
        }
        guard directoryDepth < RecordingShieldProfile.maximumPackageDirectoryDepth else {
          close(descriptor)
          result.append(.init(path: path, kind: .unsafe, sha256: nil))
          continue
        }
        result.append(.init(path: path, kind: .directory, sha256: nil))
        do {
          try visit(
            directoryDescriptor: descriptor,
            relativeDirectory: path,
            directoryDepth: directoryDepth + 1,
            shouldHashRegularFile: shouldHashRegularFile,
            result: &result
          )
          close(descriptor)
        } catch {
          close(descriptor)
          throw error
        }
      default:
        result.append(.init(path: path, kind: .unsafe, sha256: nil))
      }
    }
  }

  private static func isUnsafeReplacementError(_ code: Int32) -> Bool {
    code == ELOOP || code == EISDIR || code == ENOTDIR
  }

  static func isExcludedRootPath(_ path: String) -> Bool {
    !path.contains("/") && RecordingShieldProfile.rootExclusions.contains(path)
  }

  static func pathProblem(_ path: String) -> Bool {
    guard !path.isEmpty, path == path.precomposedStringWithCanonicalMapping, !path.hasPrefix("/"),
      !path.hasSuffix("/"), !path.contains("\\"), !path.contains("\0")
    else { return true }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return true }
    let first = parts[0].utf8
    return first.count >= 2
      && ((65...90).contains(first[first.startIndex])
        || (97...122).contains(first[first.startIndex]))
      && first[first.index(after: first.startIndex)] == 58
  }
}
