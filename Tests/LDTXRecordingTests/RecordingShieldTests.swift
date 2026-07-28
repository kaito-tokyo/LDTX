// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import LDTXRecording

struct RecordingShieldTests {
  @Test func sealsAndVerifiesClosedWorldPackage() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    let statement = try RecordingShieldSealer().seal(packageAt: root)
    #expect(statement.subject.map(\.name) == [".finalized", "Media/video.mp4"])
    #expect(RecordingShieldVerifier().verify(packageAt: root).status == .valid)
  }

  @Test func reportsModifiedMissingAndUnexpectedTogether() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try RecordingShieldSealer().seal(packageAt: root)
    try Data("changed".utf8).write(to: root.appendingPathComponent("Media/video.mp4"))
    try FileManager.default.removeItem(at: root.appendingPathComponent(".finalized"))
    try Data("new".utf8).write(to: root.appendingPathComponent("Markers/new.txt"))
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(Set(result.issues.map(\.kind)) == [.modified, .missing, .unexpected])
    #expect(result.issues.filter { $0.path == ".finalized" && $0.kind == .missing }.count == 1)
  }

  @Test func rootExclusionsAreIgnoredButNestedNamesAreCovered() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try Data("helper".utf8).write(to: root.appendingPathComponent("SHA256SUM"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: root.appendingPathComponent("Nested/.shield.json"))
    let value = try RecordingShieldSealer().seal(packageAt: root)
    #expect(!value.subject.contains { $0.name == "SHA256SUM" })
    #expect(value.subject.contains { $0.name == "Nested/.shield.json" })
  }

  @Test func refusesUnfinalizedAndExistingShield() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: root.appendingPathComponent(".finalized"))
    #expect(throws: RecordingShieldSealingError.packageNotFinalized) { try RecordingShieldSealer().seal(packageAt: root) }
    try Data().write(to: root.appendingPathComponent(".finalized"))
    try RecordingShieldSealer().seal(packageAt: root)
    #expect(throws: RecordingShieldSealingError.shieldAlreadyExists) { try RecordingShieldSealer().seal(packageAt: root) }
  }

  @Test func rejectsNonRegularOrNonemptyFinalizationMarker() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent(".finalized")
    try Data("not empty".utf8).write(to: marker)
    #expect(throws: RecordingShieldSealingError.invalidFinalizedMarker) {
      try RecordingShieldSealer().seal(packageAt: root)
    }
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
    #expect(throws: RecordingShieldSealingError.invalidFinalizedMarker) {
      try RecordingShieldSealer().seal(packageAt: root)
    }
  }

  @Test func rejectsSymlinkWithoutFollowingIt() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Media/video.mp4"))
    #expect(throws: RecordingShieldSealingError.unsafeEntry("link")) { try RecordingShieldSealer().seal(packageAt: root) }
  }

  @Test func rejectsSymbolicLinkShieldManifestWithoutFollowingIt() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try RecordingShieldSealer().seal(packageAt: root)
    let manifest = root.appendingPathComponent(".shield.json")
    let replacement = root.appendingPathComponent("replacement.json")
    try FileManager.default.moveItem(at: manifest, to: replacement)
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: replacement)
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.map(\.kind) == [.unsafeEntry])
  }

  @Test func rejectsNonRegularShieldManifestWithoutReadingIt() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try RecordingShieldSealer().seal(packageAt: root)
    let manifest = root.appendingPathComponent(".shield.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.map(\.kind) == [.unsafeEntry])
  }

  @Test func reportsUnsafeExcludedRootEntry() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try RecordingShieldSealer().seal(packageAt: root)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("SHA256SUM"),
      withDestinationURL: root.appendingPathComponent("Media/video.mp4")
    )
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.contains { $0.kind == .unsafeEntry && $0.path == "SHA256SUM" })
  }

  @Test func sealerRejectsUnsafeExcludedRootEntry() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("SHA256SUM"),
      withDestinationURL: root.appendingPathComponent("Media/video.mp4")
    )
    #expect(throws: RecordingShieldSealingError.unsafeEntry("SHA256SUM")) {
      try RecordingShieldSealer().seal(packageAt: root)
    }
  }

  @Test func rejectsCaseFoldCollisionInManifest() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    var value = try RecordingShieldSealer().seal(packageAt: root)
    value.subject.append(.init(name: "Media/VIDEO.mp4", sha256: value.subject[1].digest.sha256))
    try RecordingShieldCodec.encode(value).write(to: root.appendingPathComponent(".shield.json"))
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.contains { $0.kind == .pathConflict && $0.path == "Media/VIDEO.mp4" })
  }

  @Test func policyMismatchIsInvalid() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    var value = try RecordingShieldSealer().seal(packageAt: root)
    value.predicate.verificationPolicy = "open-world"
    try RecordingShieldCodec.encode(value).write(to: root.appendingPathComponent(".shield.json"))
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.contains { $0.kind == .policyMismatch })
  }

  @Test func noShieldIsUnverifiable() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .unverifiable)
    #expect(result.reason == .noShield)
  }

  @Test func rejectsNonUTF8Manifest() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try RecordingShieldSealer().seal(packageAt: root)
    try Data([0xFF, 0xFE, 0x7B, 0x00]).write(to: root.appendingPathComponent(".shield.json"))
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.map(\.kind) == [.malformedManifest])
  }

  @Test func rejectsEscapedDuplicateJSONMemberName() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    let statement = try RecordingShieldSealer().seal(packageAt: root)
    var manifest = String(data: try RecordingShieldCodec.encode(statement), encoding: .utf8)!
    let member = "\"_type\" : \"https://in-toto.io/Statement/v1\""
    manifest = manifest.replacingOccurrences(
      of: member,
      with: "\"_type\" : \"https://in-toto.io/Statement/v1\", \"\\u005ftype\" : \"https://in-toto.io/Statement/v1\""
    )
    try Data(manifest.utf8).write(to: root.appendingPathComponent(".shield.json"))
    let result = RecordingShieldVerifier().verify(packageAt: root)
    #expect(result.status == .invalid)
    #expect(result.issues.map(\.kind) == [.malformedManifest])
  }

  @Test func rejectsManifestExceedingJSONNestingLimit() throws {
    let data = Data((String(repeating: "[", count: RecordingShieldProfile.maximumJSONNestingDepth + 1) + "null" + String(repeating: "]", count: RecordingShieldProfile.maximumJSONNestingDepth + 1)).utf8)
    #expect(throws: CocoaError.self) { try RecordingShieldCodec.decode(data) }
  }

  @Test func acceptsColonInOrdinaryRootFileName() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    try Data("video".utf8).write(to: root.appendingPathComponent("take:1.txt"))
    try RecordingShieldSealer().seal(packageAt: root)
    #expect(RecordingShieldVerifier().verify(packageAt: root).status == .valid)
  }

  @Test func rejectsPackageExceedingDirectoryDepthLimit() throws {
    let root = try package(); defer { try? FileManager.default.removeItem(at: root) }
    var directory = root
    for _ in 0...RecordingShieldProfile.maximumPackageDirectoryDepth {
      directory.appendPathComponent("a", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let relativePath = Array(repeating: "a", count: RecordingShieldProfile.maximumPackageDirectoryDepth + 1).joined(separator: "/")
    #expect(throws: RecordingShieldSealingError.unsafeEntry(relativePath)) {
      try RecordingShieldSealer().seal(packageAt: root)
    }
  }

  private func package() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Markers"), withIntermediateDirectories: true)
    try Data("video".utf8).write(to: root.appendingPathComponent("Media/video.mp4"))
    try Data().write(to: root.appendingPathComponent(".finalized"))
    return root
  }
}
