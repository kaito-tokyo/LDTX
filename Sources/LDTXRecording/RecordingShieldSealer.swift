// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

public enum RecordingShieldSealingError: Error, LocalizedError, Equatable, Sendable {
  case packageNotFinalized, invalidFinalizedMarker, shieldAlreadyExists, unsafeEntry(String), invalidPath(String), pathConflict(String)
  public var errorDescription: String? { switch self {
  case .packageNotFinalized: "Recording package is not finalized."
  case .invalidFinalizedMarker: "Recording package finalization marker is not a zero-byte regular file."
  case .shieldAlreadyExists: "Recording Shield already exists."
  case .unsafeEntry(let path): "Unsafe package entry: \(path)"
  case .invalidPath(let path): "Invalid package path: \(path)"
  case .pathConflict(let path): "Conflicting package path: \(path)" } }
}

public struct RecordingShieldSealer: Sendable {
  public init() {}
  @discardableResult public func seal(packageAt root: URL) throws -> RecordingShieldStatement {
    let fm = FileManager.default
    let lockURL = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).shield.lock")
    let lockDescriptor = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(lockDescriptor) }
    guard flock(lockDescriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { flock(lockDescriptor, LOCK_UN) }
    let finalized = root.appendingPathComponent(RecordingPackage.finalizedMarkerFileName)
    var finalizedStat = stat()
    guard lstat(finalized.path, &finalizedStat) == 0 else { throw RecordingShieldSealingError.packageNotFinalized }
    guard (finalizedStat.st_mode & S_IFMT) == S_IFREG, finalizedStat.st_size == 0 else {
      throw RecordingShieldSealingError.invalidFinalizedMarker
    }
    let output = root.appendingPathComponent(RecordingShieldProfile.manifestFileName)
    guard !fm.fileExists(atPath: output.path) else { throw RecordingShieldSealingError.shieldAlreadyExists }
    let snapshotSubjects = try subjects(from: RecordingShieldEntries.collect(at: root))
    guard try subjects(from: RecordingShieldEntries.collect(at: root)) == snapshotSubjects else {
      throw CocoaError(.fileWriteUnknown)
    }
    let value = RecordingShieldStatement(subject: snapshotSubjects); let data = try RecordingShieldCodec.encode(value)
    guard data.count <= RecordingShieldProfile.maximumManifestSize else { throw CocoaError(.fileWriteUnknown) }
    let temporary = root.appendingPathComponent(".shield.json.tmp.\(UUID().uuidString)")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
      try handle.close()
      guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, output.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST { throw RecordingShieldSealingError.shieldAlreadyExists }
        throw CocoaError(.fileWriteUnknown)
      }
    } catch {
      try? handle.close()
      try? fm.removeItem(at: temporary)
      throw error
    }
    return value
  }

  private func subjects(from entries: [RecordingShieldEntry]) throws -> [RecordingShieldStatement.Subject] {
    var normalized = Set([RecordingShieldProfile.manifestFileName]), folded = Set([RecordingShieldProfile.manifestFileName]), subjects: [RecordingShieldStatement.Subject] = []
    for entry in entries {
      if RecordingShieldEntries.pathProblem(entry.path) { throw RecordingShieldSealingError.invalidPath(entry.path) }
      let nfc = entry.path.precomposedStringWithCanonicalMapping
      let fold = nfc.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      guard normalized.insert(nfc).inserted, folded.insert(fold).inserted else { throw RecordingShieldSealingError.pathConflict(entry.path) }
      switch entry.kind {
      case .regular:
        if !RecordingShieldEntries.isExcludedRootPath(entry.path) {
          guard let sha256 = entry.sha256 else { throw CocoaError(.fileReadCorruptFile) }
          subjects.append(.init(name: nfc, sha256: sha256))
        }
      case .directory: break
      case .unsafe: throw RecordingShieldSealingError.unsafeEntry(entry.path)
      }
    }
    return subjects.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
  }
}
