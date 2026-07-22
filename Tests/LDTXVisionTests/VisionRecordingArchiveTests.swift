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
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let archive = VisionRecordingArchive()

        let artifact = try await archive.saveThrowing(
            image: image,
            vision: vision,
            analysis: analysis,
            recordingPackageDirectory: root,
            timestamp: timestamp
        )

        let directory = root
            .appendingPathComponent("vision", isDirectory: true)
            .appendingPathComponent("Scene_Detection", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let jpegURL = try #require(files.first { $0.pathExtension == "jpg" })
        let jsonURL = try #require(files.first { $0.pathExtension == "json" })
        #expect(jpegURL.deletingPathExtension().lastPathComponent == jsonURL.deletingPathExtension().lastPathComponent)

        let source = try #require(CGImageSourceCreateWithURL(jpegURL as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 512)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 288)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(VisionRecordingMetadata.self, from: Data(contentsOf: jsonURL))
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.visionID == vision.id)
        #expect(metadata.visionName == vision.name)
        #expect(metadata.output == "LB")
        #expect(metadata.imageFileName == jpegURL.lastPathComponent)
        #expect(metadata.imagePixelWidth == 512)
        #expect(metadata.imagePixelHeight == 288)
        #expect(metadata.promptTokenCount == 208)

        await archive.remove(artifact)
        #expect(!FileManager.default.fileExists(atPath: artifact.imageURL.path))
        #expect(!FileManager.default.fileExists(atPath: artifact.metadataURL.path))
    }
}
