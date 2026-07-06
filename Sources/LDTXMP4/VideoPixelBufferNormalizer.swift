// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation

public final class VideoPixelBufferNormalizer: @unchecked Sendable {
    public let width: Int
    public let height: Int

    private let pixelBufferPool: CVPixelBufferPool
    private var pixelBuffers: [CVPixelBuffer]
    private var nextPixelBufferIndex = 0

    public init(width: Int, height: Int, minimumBufferCount: Int = 24) throws {
        guard width > 0, height > 0, minimumBufferCount > 0 else {
            throw VideoPixelBufferNormalizerError.invalidConfiguration
        }

        self.width = width
        self.height = height
        pixelBufferPool = try Self.makePixelBufferPool(
            width: width,
            height: height,
            minimumBufferCount: minimumBufferCount
        )
        pixelBuffers = try Self.prewarmPixelBufferPool(pixelBufferPool, minimumBufferCount: minimumBufferCount)
    }

    public func normalizedPixelBuffer(from sourcePixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(sourcePixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(sourcePixelBuffer) == width,
              CVPixelBufferGetHeight(sourcePixelBuffer) == height,
              CVPixelBufferGetPlaneCount(sourcePixelBuffer) == 2 else {
            return nil
        }

        guard !pixelBuffers.isEmpty else {
            return nil
        }
        let destinationPixelBuffer = pixelBuffers[nextPixelBufferIndex]
        nextPixelBufferIndex = (nextPixelBufferIndex + 1) % pixelBuffers.count

        CVPixelBufferLockBaseAddress(sourcePixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(destinationPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destinationPixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, .readOnly)
        }

        for planeIndex in 0..<2 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(sourcePixelBuffer, planeIndex),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destinationPixelBuffer, planeIndex) else {
                return nil
            }

            let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, planeIndex)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destinationPixelBuffer, planeIndex)
            let planeWidth = CVPixelBufferGetWidthOfPlane(sourcePixelBuffer, planeIndex)
            let planeHeight = CVPixelBufferGetHeightOfPlane(sourcePixelBuffer, planeIndex)
            let activeBytesPerRow = planeIndex == 0 ? planeWidth : planeWidth * 2
            let bytesPerRowToCopy = min(sourceBytesPerRow, destinationBytesPerRow, activeBytesPerRow)
            guard bytesPerRowToCopy > 0, planeHeight > 0 else { return nil }

            for rowIndex in 0..<planeHeight {
                memcpy(
                    destinationBaseAddress.advanced(by: rowIndex * destinationBytesPerRow),
                    sourceBaseAddress.advanced(by: rowIndex * sourceBytesPerRow),
                    bytesPerRowToCopy
                )
            }
        }

        return destinationPixelBuffer
    }

    private static func makePixelBufferPool(
        width: Int,
        height: Int,
        minimumBufferCount: Int
    ) throws -> CVPixelBufferPool {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pixelBufferPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )
        guard status == kCVReturnSuccess, let pixelBufferPool else {
            throw VideoPixelBufferNormalizerError.pixelBufferPoolCreationFailed(status)
        }
        return pixelBufferPool
    }

    private static func prewarmPixelBufferPool(
        _ pixelBufferPool: CVPixelBufferPool,
        minimumBufferCount: Int
    ) throws -> [CVPixelBuffer] {
        var prewarmedPixelBuffers: [CVPixelBuffer] = []
        prewarmedPixelBuffers.reserveCapacity(minimumBufferCount)

        for _ in 0..<minimumBufferCount {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pixelBufferPool,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw VideoPixelBufferNormalizerError.pixelBufferPoolPrewarmFailed(status)
            }
            prewarmedPixelBuffers.append(pixelBuffer)
        }
        return prewarmedPixelBuffers
    }
}

public enum VideoPixelBufferNormalizerError: Error, LocalizedError {
    case invalidConfiguration
    case pixelBufferPoolCreationFailed(CVReturn)
    case pixelBufferPoolPrewarmFailed(CVReturn)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The video pixel buffer normalizer configuration is invalid."
        case let .pixelBufferPoolCreationFailed(status):
            "CVPixelBufferPoolCreate failed with status \(status)."
        case let .pixelBufferPoolPrewarmFailed(status):
            "CVPixelBufferPool prewarm failed with status \(status)."
        }
    }
}
