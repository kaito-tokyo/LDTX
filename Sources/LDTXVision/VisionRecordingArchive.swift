// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import ImageIO
import LDTXWorkspace
import OSLog
import UniformTypeIdentifiers

private let visionArchiveLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "vision-archive"
)

public struct VisionRecordingMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var timestamp: Date
    public var visionID: String
    public var visionName: String
    public var modelRepositoryID: String
    public var modelRevision: String?
    public var systemPrompt: String
    public var userPrompt: String
    public var output: String
    public var elapsedSeconds: TimeInterval
    public var promptTokenCount: Int?
    public var generationTokenCount: Int?
    public var promptTokensPerSecond: Double?
    public var tokensPerSecond: Double?
    public var imageFileName: String
    public var imagePixelWidth: Int
    public var imagePixelHeight: Int
}

public struct VisionRecordingArtifact: Sendable {
    public let imageURL: URL
    public let metadataURL: URL
}

public actor VisionRecordingArchive {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let fileManager: FileManager
    private let jpegQuality: CGFloat
    private let maximumImageDimension: CGFloat

    public init(
        fileManager: FileManager = .default,
        jpegQuality: CGFloat = 0.3,
        maximumImageDimension: CGFloat = 512
    ) {
        self.fileManager = fileManager
        self.jpegQuality = jpegQuality
        self.maximumImageDimension = maximumImageDimension
    }

    public func save(
        image: CIImage,
        vision: WorkspaceVisionDefinition,
        analysis: VisionAnalysis,
        recordingPackageDirectory: URL,
        timestamp: Date = Date()
    ) -> VisionRecordingArtifact? {
        do {
            return try saveThrowing(
                image: image,
                vision: vision,
                analysis: analysis,
                recordingPackageDirectory: recordingPackageDirectory,
                timestamp: timestamp
            )
        } catch {
            visionArchiveLogger.error(
                "Vision archive write failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    public func saveThrowing(
        image: CIImage,
        vision: WorkspaceVisionDefinition,
        analysis: VisionAnalysis,
        recordingPackageDirectory: URL,
        timestamp: Date = Date()
    ) throws -> VisionRecordingArtifact {
        let image = resizedImage(image)
        let extent = image.extent.integral
        guard !extent.isEmpty,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let renderedImage = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace),
              let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw VisionRecordingArchiveError.jpegEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            renderedImage,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw VisionRecordingArchiveError.jpegEncodingFailed
        }
        let jpeg = destinationData as Data

        let directory = recordingPackageDirectory
            .appendingPathComponent("vision", isDirectory: true)
            .appendingPathComponent(safePathComponent(vision.id), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = Self.fileStem(timestamp: timestamp)
        let imageFileName = "\(stem).jpg"
        let metadataFileName = "\(stem).json"
        let metadata = VisionRecordingMetadata(
            schemaVersion: 1,
            timestamp: timestamp,
            visionID: vision.id,
            visionName: vision.name,
            modelRepositoryID: vision.model.repositoryID,
            modelRevision: vision.model.revision,
            systemPrompt: vision.systemPrompt,
            userPrompt: vision.userPrompt,
            output: analysis.output,
            elapsedSeconds: analysis.elapsedSeconds,
            promptTokenCount: analysis.promptTokenCount,
            generationTokenCount: analysis.generationTokenCount,
            promptTokensPerSecond: analysis.promptTokensPerSecond,
            tokensPerSecond: analysis.tokensPerSecond,
            imageFileName: imageFileName,
            imagePixelWidth: Int(extent.width),
            imagePixelHeight: Int(extent.height)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)

        let artifact = VisionRecordingArtifact(
            imageURL: directory.appendingPathComponent(imageFileName),
            metadataURL: directory.appendingPathComponent(metadataFileName)
        )
        do {
            try jpeg.write(to: artifact.imageURL, options: Data.WritingOptions.atomic)
            try metadataData.write(
                to: artifact.metadataURL,
                options: Data.WritingOptions.atomic
            )
            return artifact
        } catch {
            try? fileManager.removeItem(at: artifact.imageURL)
            try? fileManager.removeItem(at: artifact.metadataURL)
            throw error
        }
    }

    public func remove(_ artifact: VisionRecordingArtifact) {
        do {
            if fileManager.fileExists(atPath: artifact.imageURL.path) {
                try fileManager.removeItem(at: artifact.imageURL)
            }
            if fileManager.fileExists(atPath: artifact.metadataURL.path) {
                try fileManager.removeItem(at: artifact.metadataURL)
            }
        } catch {
            visionArchiveLogger.error(
                "Stale Vision archive removal failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func resizedImage(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(maximumImageDimension / max(extent.width, extent.height), 1)
        return image
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(sanitized)
        return result.isEmpty ? "vision" : result
    }

    private static func fileStem(timestamp: Date) -> String {
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        return "\(milliseconds)-\(UUID().uuidString.lowercased())"
    }
}

public enum VisionRecordingArchiveError: Error, LocalizedError {
    case jpegEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .jpegEncodingFailed:
            "The Vision input image could not be encoded as JPEG."
        }
    }
}
