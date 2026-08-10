// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import ImageIO
import LDTXVision
import LDTXWorkspace
import Testing

struct VisionRecordingArchiveTests {
  @Test func savesScaledJPEGAndMetadataInVisionDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathExtension("ldtxrecord")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let vision = WorkspaceVisionDefinition(
      name: "Scene Detection",
      model: WorkspaceVisionModel(repositoryID: "example/model", revision: "revision"),
      systemPrompt: "system",
      userPrompt: "user"
    )
    let analysis = VisionAnalysis(
      output: "LB",
      elapsedSeconds: 0.25,
      promptTokenCount: 208,
      generationTokenCount: 1,
      promptTokensPerSecond: 800,
      tokensPerSecond: 20
    )
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let timelineMilliseconds: UInt64 = 90_123
    let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
      .cropped(to: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
    let archive = VisionRecordingArchive()

    let artifact = try await archive.saveThrowing(
      image: image,
      vision: vision,
      analysis: analysis,
      recordingPackageDirectory: root,
      timelineMilliseconds: timelineMilliseconds,
      timestamp: timestamp
    )

    let directory =
      root
      .appendingPathComponent("Visions", isDirectory: true)
      .appendingPathComponent("Scene Detection", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    let jpegURL = try #require(files.first { $0.pathExtension == "jpg" })
    let jsonURL = try #require(files.first { $0.pathExtension == "json" })
    #expect(
      jpegURL.deletingPathExtension().lastPathComponent
        == jsonURL.deletingPathExtension().lastPathComponent)
    #expect(jpegURL.deletingPathExtension().lastPathComponent == "time-90123ms")

    let source = try #require(CGImageSourceCreateWithURL(jpegURL as CFURL, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 512)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 288)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let metadata = try decoder.decode(VisionRecordingMetadata.self, from: Data(contentsOf: jsonURL))
    #expect(metadata.schemaVersion == 4)
    #expect(metadata.recordingTimelineMilliseconds == timelineMilliseconds)
    #expect(metadata.visionID == vision.id)
    #expect(metadata.visionName == vision.name)
    #expect(metadata.output == "LB")
    #expect(metadata.imageFileName == jpegURL.lastPathComponent)
    #expect(metadata.imagePixelWidth == 512)
    #expect(metadata.imagePixelHeight == 288)
    #expect(metadata.promptTokenCount == 208)
    guard case .visionLanguageModel(let definition) = metadata.definition else {
      Issue.record("Expected VLM recording metadata")
      return
    }
    #expect(definition.modelRepositoryID == "example/model")
    #expect(definition.modelRevision == "revision")
    #expect(definition.systemPrompt == "system")
    #expect(definition.userPrompt == "user")

    await archive.remove(artifact)
    #expect(!FileManager.default.fileExists(atPath: artifact.imageURL.path))
    #expect(!FileManager.default.fileExists(atPath: artifact.metadataURL.path))
  }

  @Test func ocrMetadataContainsNoVisionLanguageModelConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathExtension("ldtxrecord")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var vision = WorkspaceVisionDefinition(name: "Score OCR")
    vision.definition = .opticalCharacterRecognition(
      .init(
        recognitionLevel: .fast,
        recognitionLanguages: ["ja-JP"],
        usesLanguageCorrection: false,
        subsamplingRate: 4
      ))
    let archive = VisionRecordingArchive()
    let artifact = try await archive.saveThrowing(
      image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)),
      vision: vision,
      analysis: VisionAnalysis(output: "42", elapsedSeconds: 0.1),
      recordingPackageDirectory: root,
      timelineMilliseconds: 1_200
    )

    let data = try Data(contentsOf: artifact.metadataURL)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("modelRepositoryID"))
    #expect(!json.contains("systemPrompt"))
    #expect(!json.contains("userPrompt"))
    #expect(!json.contains("promptTokenCount"))
    #expect(!json.contains("generationTokenCount"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let metadata = try decoder.decode(VisionRecordingMetadata.self, from: data)
    guard case .opticalCharacterRecognition(let definition) = metadata.definition else {
      Issue.record("Expected OCR recording metadata")
      return
    }
    #expect(definition.recognitionLevel == .fast)
    #expect(definition.recognitionLanguages == ["ja-JP"])
    #expect(!definition.usesLanguageCorrection)
    #expect(definition.subsamplingRate == 4)
  }

  @Test func rejectsDuplicateTimelineTimestampWithoutOverwritingExistingArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathExtension("ldtxrecord")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let archive = VisionRecordingArchive()
    let vision = WorkspaceVisionDefinition(name: "Repeated Frame")
    let timelineMilliseconds: UInt64 = 1_234
    let image = CIImage(color: .white)
      .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
    let first = try await archive.saveThrowing(
      image: image,
      vision: vision,
      analysis: VisionAnalysis(output: "first", elapsedSeconds: 0.1),
      recordingPackageDirectory: root,
      timelineMilliseconds: timelineMilliseconds
    )
    let originalMetadata = try Data(contentsOf: first.metadataURL)

    await #expect(throws: VisionRecordingArchiveError.duplicateTimelineTimestamp) {
      try await archive.saveThrowing(
        image: image,
        vision: vision,
        analysis: VisionAnalysis(output: "second", elapsedSeconds: 0.1),
        recordingPackageDirectory: root,
        timelineMilliseconds: timelineMilliseconds
      )
    }

    #expect(try Data(contentsOf: first.metadataURL) == originalMetadata)
    #expect(FileManager.default.fileExists(atPath: first.imageURL.path))
  }

  @Test func percentEncodesReservedResourceNameCharacters() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathExtension("ldtxrecord")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let archive = VisionRecordingArchive()
    let vision = WorkspaceVisionDefinition(name: "Score./100%")
    let artifact = try await archive.saveThrowing(
      image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9)),
      vision: vision,
      analysis: VisionAnalysis(output: "ok", elapsedSeconds: 0.1),
      recordingPackageDirectory: root,
      timelineMilliseconds: 1
    )

    #expect(artifact.imageURL.deletingLastPathComponent().lastPathComponent == "Score%2E%2F100%25")
  }
}
