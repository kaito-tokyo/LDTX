// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
@testable import LDTXWorkspaceAppletService
import Testing

extension OutputTestSuite {
  @Suite struct VisionResultArchiverIntegrationTestSuite {
    private let date = Date(timeIntervalSince1970: 123)
    private var image: CIImage {
      CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    private func archive(_ archiver: VisionResultArchiver, at root: URL) throws {
      try archiver.archive(
        internalID: 41, image: image, output: "private OCR text",
        timelineMilliseconds: 99, packageDirectory: root)
    }

    private func temporaryDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      return root
    }

    @Test(
      "LUB-1070: Operation failure rolls back and preserves cause",
      arguments: VisionResultArchiver.Operation.allCases)
    func operationFailureRollsBackAndPreservesCause(operation: VisionResultArchiver.Operation)
      throws
    {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let cause = NSError(domain: NSPOSIXErrorDomain, code: 28)
      let archiver = VisionResultArchiver(
        currentDate: { date },
        beforeOperation: {
          if $0 == operation { throw cause }
        })
      do {
        try archive(archiver, at: root)
        Issue.record("Expected injected failure")
      } catch {
        let error = error as NSError
        #expect((error.userInfo[NSUnderlyingErrorKey] as? NSError) === cause)
        #expect(error.userInfo["VisionArchiveOperation"] as? String == operation.rawValue)
        #expect(error.userInfo["VisionArchiveResult"] as? String == "vision-41-123000")
        #expect(error.userInfo[NSURLErrorKey] as? URL == root)
        #expect((error.userInfo["VisionArchiveCleanupErrors"] as? [NSError])?.isEmpty == true)
        #expect(!error.localizedDescription.contains(root.path))
        #expect(!error.localizedDescription.contains("private OCR text"))
      }
      let directory = root.appendingPathComponent("Visions")
      if FileManager.default.fileExists(atPath: directory.path) {
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
      }
    }

    @Test("LUB-1070: Collision preserves existing output", arguments: ["jpg", "json"])
    func collisionPreservesExistingOutput(ext: String) throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory = root.appendingPathComponent("Visions")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let existing = directory.appendingPathComponent("vision-41-123000.\(ext)")
      let sentinel = Data("existing output".utf8)
      try sentinel.write(to: existing)
      #expect(throws: (any Error).self) {
        try archive(VisionResultArchiver(currentDate: { date }), at: root)
      }
      #expect(try Data(contentsOf: existing) == sentinel)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
          existing.lastPathComponent
        ])
    }

    @Test("LUB-1070: Partial metadata write is removed") func partialMetadataWriteIsRemoved() throws
    {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let cause = NSError(domain: NSPOSIXErrorDomain, code: 28)
      let archiver = VisionResultArchiver(
        currentDate: { date },
        writeMetadata: { _, url in
          try Data("partial JSON".utf8).write(to: url)
          throw cause
        })
      do {
        try archive(archiver, at: root)
        Issue.record("Expected partial metadata write failure")
      } catch {
        #expect(((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError) === cause)
      }
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: root.appendingPathComponent("Visions").path
        ).isEmpty)
    }

    @Test("LUB-1070: Cleanup failure does not replace write failure")
    func cleanupFailureDoesNotReplaceWriteFailure() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let manager = ArchiveCleanupFailingFileManager()
      let cause = NSError(domain: NSPOSIXErrorDomain, code: 28)
      let archiver = VisionResultArchiver(
        fileManager: manager, currentDate: { date },
        beforeOperation: {
          if $0 == .metadataPublication { throw cause }
        })
      do {
        try archive(archiver, at: root)
        Issue.record("Expected injected failure")
      } catch {
        let error = error as NSError
        #expect((error.userInfo[NSUnderlyingErrorKey] as? NSError) === cause)
        let secondary = try #require(error.userInfo["VisionArchiveCleanupErrors"] as? [NSError])
        #expect(secondary.count == 2)
        #expect(secondary.allSatisfy { $0 === manager.failure })
      }
    }

    @Test("LUB-1070: Success writes readable pair and no staging files")
    func successWritesReadablePairAndNoStagingFiles() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      try archive(VisionResultArchiver(currentDate: { date }), at: root)
      let directory = root.appendingPathComponent("Visions")
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      #expect(Set(files.map(\.pathExtension)) == ["jpg", "json"])
      #expect(files.count == 2)
      let metadata =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: directory.appendingPathComponent("vision-41-123000.json")))
        as? [String: String]
      #expect(
        metadata == [
          "visionID": "41", "output": "private OCR text", "recordingTimelineMilliseconds": "99",
        ])
      #expect(
        try !Data(contentsOf: directory.appendingPathComponent("vision-41-123000.jpg")).isEmpty)
    }
  }
}

private final class ArchiveCleanupFailingFileManager: FileManager, @unchecked Sendable {
  let failure = NSError(domain: NSPOSIXErrorDomain, code: 13)
  override func removeItem(at URL: URL) throws { throw failure }
}
