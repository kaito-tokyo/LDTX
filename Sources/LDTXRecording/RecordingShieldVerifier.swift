// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

public enum RecordingShieldIssueKind: String, Codable, Equatable, Sendable {
  case missing, modified, unexpected, unsafeEntry, malformedManifest, pathConflict, policyMismatch
}

public struct RecordingShieldIssue: Codable, Equatable, Sendable {
  public var kind: RecordingShieldIssueKind
  public var path: String?
  public var message: String
  public init(kind: RecordingShieldIssueKind, path: String? = nil, message: String) {
    self.kind = kind
    self.path = path
    self.message = message
  }
}

public enum RecordingShieldUnverifiableReason: String, Codable, Equatable, Sendable {
  case noShield, unreadable, unsupportedProfile, ioFailure
}

public struct RecordingShieldVerificationResult: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Equatable, Sendable { case valid, invalid, unverifiable }
  public var status: Status
  public var issues: [RecordingShieldIssue]
  public var reason: RecordingShieldUnverifiableReason?
  public init(
    status: Status, issues: [RecordingShieldIssue] = [],
    reason: RecordingShieldUnverifiableReason? = nil
  ) {
    self.status = status
    self.issues = issues
    self.reason = reason
  }
}

public struct RecordingShieldVerifier: Sendable {
  public init() {}
  public func verify(packageAt root: URL) -> RecordingShieldVerificationResult {
    let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { return .init(status: .unverifiable, reason: .ioFailure) }
    defer { close(rootDescriptor) }
    let manifestDescriptor = openat(
      rootDescriptor, RecordingShieldProfile.manifestFileName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard manifestDescriptor >= 0 else {
      if errno == ENOENT { return .init(status: .unverifiable, reason: .noShield) }
      if errno == ELOOP {
        return .init(
          status: .invalid,
          issues: [
            .init(
              kind: .unsafeEntry, path: RecordingShieldProfile.manifestFileName,
              message: "Shield manifest must be a regular file and must not be a symbolic link.")
          ])
      }
      var entryStat = stat()
      if fstatat(
        rootDescriptor, RecordingShieldProfile.manifestFileName, &entryStat, AT_SYMLINK_NOFOLLOW)
        == 0,
        (entryStat.st_mode & S_IFMT) != S_IFREG
      {
        return .init(
          status: .invalid,
          issues: [
            .init(
              kind: .unsafeEntry, path: RecordingShieldProfile.manifestFileName,
              message: "Shield manifest must be a regular file.")
          ])
      }
      return .init(status: .unverifiable, reason: .ioFailure)
    }
    var manifestStat = stat()
    guard fstat(manifestDescriptor, &manifestStat) == 0 else {
      close(manifestDescriptor)
      return .init(status: .unverifiable, reason: .ioFailure)
    }
    guard (manifestStat.st_mode & S_IFMT) == S_IFREG else {
      close(manifestDescriptor)
      return .init(
        status: .invalid,
        issues: [
          .init(
            kind: .unsafeEntry,
            path: RecordingShieldProfile.manifestFileName,
            message: "Shield manifest must be a regular file and must not be a symbolic link."
          )
        ]
      )
    }
    guard manifestStat.st_size <= RecordingShieldProfile.maximumManifestSize else {
      close(manifestDescriptor)
      return .init(
        status: .invalid,
        issues: [
          .init(
            kind: .malformedManifest, path: RecordingShieldProfile.manifestFileName,
            message: "Shield manifest exceeds the maximum supported size.")
        ])
    }
    let data: Data
    do {
      let handle = FileHandle(fileDescriptor: manifestDescriptor, closeOnDealloc: true)
      data = try handle.readToEnd() ?? Data()
      try handle.close()
    } catch { return .init(status: .unverifiable, reason: .unreadable) }
    let statement: RecordingShieldStatement
    do { statement = try RecordingShieldCodec.decode(data) } catch {
      return .init(
        status: .invalid,
        issues: [
          .init(
            kind: .malformedManifest, message: "Shield JSON does not match the statement schema.")
        ])
    }
    guard statement.type == RecordingShieldProfile.statementType,
      statement.predicateType == RecordingShieldProfile.predicateType,
      statement.predicate.profileVersion == RecordingShieldProfile.profileVersion
    else { return .init(status: .unverifiable, reason: .unsupportedProfile) }

    var issues: [RecordingShieldIssue] = []
    let p = statement.predicate
    if p.packageRoot != RecordingShieldProfile.packageRoot
      || p.digestAlgorithm != RecordingShieldProfile.digestAlgorithm
      || p.pathPolicy != RecordingShieldProfile.pathPolicy
      || p.entryPolicy != RecordingShieldProfile.entryPolicy
      || p.verificationPolicy != RecordingShieldProfile.verificationPolicy
    {
      issues.append(
        .init(
          kind: .policyMismatch,
          message: "Shield policy values do not exactly match Recording Shield v1."))
    }

    var listed: [String: String] = [:]
    var normalized = Set<String>()
    var folded = Set<String>()
    var priorName: String?
    for subject in statement.subject {
      let name = subject.name
      if RecordingShieldEntries.pathProblem(name) {
        issues.append(
          .init(kind: .malformedManifest, path: name, message: "Subject path is not canonical."))
        continue
      }
      if let priorName, !Array(priorName.utf8).lexicographicallyPrecedes(Array(name.utf8)) {
        issues.append(
          .init(
            kind: .malformedManifest, path: name,
            message: "Subjects are not uniquely ordered by UTF-8 bytes."))
      }
      priorName = name
      let fold = name.folding(
        options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      if !normalized.insert(name.precomposedStringWithCanonicalMapping).inserted
        || !folded.insert(fold).inserted
      {
        issues.append(
          .init(
            kind: .pathConflict, path: name,
            message: "Subject path has an NFC or case-fold collision."))
      }
      let digest = subject.digest.sha256
      if digest.count != 64
        || digest.contains(where: {
          !("0"..."9").contains(String($0)) && !("a"..."f").contains(String($0))
        })
      {
        issues.append(
          .init(
            kind: .malformedManifest, path: name,
            message: "SHA-256 digest must be 64 lowercase hexadecimal digits."))
        continue
      }
      listed[name] = digest
    }

    let entries: [RecordingShieldEntry]
    do {
      entries = try RecordingShieldEntries.collect(directoryDescriptor: rootDescriptor) { path in
        listed[path] != nil && !RecordingShieldEntries.isExcludedRootPath(path)
      }
    } catch RecordingShieldEntriesError.invalidPath(let path) {
      issues.append(
        .init(
          kind: .unsafeEntry, path: path.isEmpty ? nil : path,
          message: "Package entry name is not valid UTF-8."))
      return .init(status: .invalid, issues: issues)
    } catch { return .init(status: .unverifiable, issues: issues, reason: .ioFailure) }
    var actualRegular = Set<String>()
    var actualNFC = Set<String>()
    var actualFolded = Set<String>()
    for entry in entries {
      if RecordingShieldEntries.pathProblem(entry.path) {
        issues.append(
          .init(
            kind: .unsafeEntry, path: entry.path, message: "Package entry path is not canonical."))
      }
      let actualNormalized = entry.path.precomposedStringWithCanonicalMapping
      let actualFold = actualNormalized.folding(
        options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      if !actualNFC.insert(actualNormalized).inserted || !actualFolded.insert(actualFold).inserted {
        issues.append(
          .init(
            kind: .pathConflict, path: entry.path,
            message: "Package path has an NFC or case-fold collision."))
      }
      switch entry.kind {
      case .unsafe:
        issues.append(
          .init(
            kind: .unsafeEntry, path: entry.path,
            message: "Package entry is not a regular file or directory."))
      case .directory: break
      case .regular:
        if RecordingShieldEntries.isExcludedRootPath(entry.path) { continue }
        actualRegular.insert(entry.path)
        guard let expected = listed[entry.path] else {
          issues.append(
            .init(
              kind: .unexpected, path: entry.path,
              message: "Regular file is not listed by the Shield."))
          continue
        }
        guard let actual = entry.sha256 else {
          return .init(status: .unverifiable, issues: issues, reason: .ioFailure)
        }
        if actual != expected {
          issues.append(
            .init(kind: .modified, path: entry.path, message: "SHA-256 digest does not match."))
        }
      }
    }
    for name in listed.keys.sorted() where !actualRegular.contains(name) {
      issues.append(.init(kind: .missing, path: name, message: "Listed regular file is missing."))
    }
    var finalizedStat = stat()
    if (fstatat(
      rootDescriptor, RecordingPackage.finalizedMarkerFileName, &finalizedStat, AT_SYMLINK_NOFOLLOW)
      != 0
      || (finalizedStat.st_mode & S_IFMT) != S_IFREG || finalizedStat.st_size != 0
      || listed[RecordingPackage.finalizedMarkerFileName] == nil)
      && !issues.contains(where: { $0.path == RecordingPackage.finalizedMarkerFileName })
    {
      issues.append(
        .init(
          kind: .missing, path: RecordingPackage.finalizedMarkerFileName,
          message:
            "A Shielded recording package requires a listed zero-byte regular .finalized marker."))
    }
    issues.sort { ($0.path ?? "", $0.kind.rawValue) < ($1.path ?? "", $1.kind.rawValue) }
    return .init(status: issues.isEmpty ? .valid : .invalid, issues: issues)
  }
}
