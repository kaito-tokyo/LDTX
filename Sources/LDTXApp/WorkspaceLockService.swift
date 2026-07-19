// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import os

struct WorkspaceLock: Equatable {
  let url: URL
  let processIdentifier: Int32
  let descriptor: Int32
}

struct WorkspaceLockConflict: Equatable {
  let processIdentifier: String?
  let comments: String
}

enum WorkspaceLockError: Error, Equatable, LocalizedError {
  case alreadyLocked(WorkspaceLockConflict)
  case invalidPackage(URL)
  case operationFailed(path: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .alreadyLocked:
      "The Workspace is already locked."
    case .invalidPackage(let url):
      "The Workspace package is not a directory: \(url.path)"
    case .operationFailed(let path, let code):
      "The Workspace lock operation failed for \(path) (errno \(code))."
    }
  }
}

struct WorkspaceLockService {
  static let fileName = "LDTX.lock"

  private let fileManager: FileManager
  private let processIdentifier: Int32
  private let now: () -> Date
  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceLock")

  init(
    fileManager: FileManager = .default,
    processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
    now: @escaping () -> Date = Date.init
  ) {
    self.fileManager = fileManager
    self.processIdentifier = processIdentifier
    self.now = now
  }

  func acquire(at packageURL: URL, createsPackageDirectory: Bool = false) throws -> WorkspaceLock {
    try ensurePackageDirectory(at: packageURL, createsIfNeeded: createsPackageDirectory)
    let lockURL = packageURL.appendingPathComponent(Self.fileName, isDirectory: false)
    let descriptor = lockURL.path.withCString {
      Darwin.open(
        $0,
        O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      let code = errno
      if code == EWOULDBLOCK {
        throw WorkspaceLockError.alreadyLocked(readConflict(at: lockURL))
      }
      throw WorkspaceLockError.operationFailed(path: lockURL.path, code: code)
    }

    do {
      let timestamp = ISO8601DateFormatter().string(from: now())
      let contents = "\(processIdentifier)\n\(timestamp)\n"
      guard Darwin.ftruncate(descriptor, 0) == 0 else {
        throw WorkspaceLockError.operationFailed(path: lockURL.path, code: errno)
      }
      guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw WorkspaceLockError.operationFailed(path: lockURL.path, code: errno)
      }
      try writeAll(Data(contents.utf8), to: descriptor, path: lockURL.path)
      guard Darwin.fsync(descriptor) == 0 else {
        throw WorkspaceLockError.operationFailed(path: lockURL.path, code: errno)
      }
      return WorkspaceLock(
        url: lockURL,
        processIdentifier: processIdentifier,
        descriptor: descriptor
      )
    } catch {
      _ = Darwin.close(descriptor)
      throw error
    }
  }

  func release(_ lock: WorkspaceLock) {
    guard Darwin.close(lock.descriptor) == 0 else {
      logger.error(
        "Workspace lock release failed while closing its descriptor: path=\(lock.url.path, privacy: .public) errno=\(errno)"
      )
      return
    }
  }

  private func ensurePackageDirectory(at url: URL, createsIfNeeded: Bool) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw WorkspaceLockError.invalidPackage(url) }
      return
    }
    guard createsIfNeeded else { throw WorkspaceLockError.invalidPackage(url) }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private func readConflict(at lockURL: URL) -> WorkspaceLockConflict {
    guard let contents = try? String(contentsOf: lockURL, encoding: .utf8) else {
      return WorkspaceLockConflict(processIdentifier: nil, comments: "")
    }
    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    let processIdentifier = lines.first.map(String.init)
    let comments = lines.dropFirst().joined(separator: "\n")
    return WorkspaceLockConflict(processIdentifier: processIdentifier, comments: comments)
  }

  private func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var written = 0
      while written < rawBuffer.count {
        let result = Darwin.write(
          descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
        guard result > 0 else {
          if result < 0, errno == EINTR { continue }
          throw WorkspaceLockError.operationFailed(path: path, code: errno)
        }
        written += result
      }
    }
  }
}
