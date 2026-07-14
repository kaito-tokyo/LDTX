// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import ImageIO
import LDTXVision
import LDTXWorkspace
import XCTest

final class VisionRecordingArchiveTests: XCTestCase {
    func testSavesScaledJPEGAndMetadataInVisionDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("ldtxrecord")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vision = WorkspaceVisionDefinition(
            id: "vision/test",
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
            .appendingPathComponent("vision_test", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let jpegURL = try XCTUnwrap(files.first { $0.pathExtension == "jpg" })
        let jsonURL = try XCTUnwrap(files.first { $0.pathExtension == "json" })
        XCTAssertEqual(jpegURL.deletingPathExtension().lastPathComponent, jsonURL.deletingPathExtension().lastPathComponent)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpegURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 288)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(VisionRecordingMetadata.self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(metadata.schemaVersion, 1)
        XCTAssertEqual(metadata.visionID, vision.id)
        XCTAssertEqual(metadata.visionName, vision.name)
        XCTAssertEqual(metadata.output, "LB")
        XCTAssertEqual(metadata.imageFileName, jpegURL.lastPathComponent)
        XCTAssertEqual(metadata.imagePixelWidth, 512)
        XCTAssertEqual(metadata.imagePixelHeight, 288)
        XCTAssertEqual(metadata.promptTokenCount, 208)

        await archive.remove(artifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.imageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.metadataURL.path))
    }
}
