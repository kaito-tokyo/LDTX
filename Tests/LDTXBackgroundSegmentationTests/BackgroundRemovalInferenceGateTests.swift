// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Metal
import XCTest
@testable import LDTXBackgroundSegmentation

final class BackgroundRemovalInferenceGateTests: XCTestCase {
    private typealias PixelRegion = (x: Range<Int>, y: Range<Int>)

    func testMetalGateReusesStableFrameAndRequestsInferenceAfterLargeChange() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this host.")
        }
        let gate = BackgroundRemovalInferenceGate(metalDevice: device)
        let textureCache = try makeTextureCache(device: device)

        let first = try makePixelBuffer(width: 8, height: 8, luma: 32)
        let firstTexture = try makeLumaTexture(pixelBuffer: first, textureCache: textureCache)
        XCTAssertTrue(gate.shouldRunInference(lumaTexture: firstTexture))
        try await waitForEvaluation(of: gate)

        let second = try makePixelBuffer(width: 8, height: 8, luma: 32)
        let secondTexture = try makeLumaTexture(pixelBuffer: second, textureCache: textureCache)
        XCTAssertFalse(gate.shouldRunInference(lumaTexture: secondTexture))
        try await waitForEvaluation(of: gate)

        let third = try makePixelBuffer(width: 8, height: 8, luma: 200)
        let thirdTexture = try makeLumaTexture(pixelBuffer: third, textureCache: textureCache)
        XCTAssertFalse(gate.shouldRunInference(lumaTexture: thirdTexture))
        try await waitForEvaluation(of: gate)

        XCTAssertTrue(gate.shouldRunInference(lumaTexture: thirdTexture))
    }

    func testMetalGateRequiresSpatialSupport() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this host.")
        }
        let insufficientChange = Array(spatialWindowCoordinates.prefix(7))
        let insufficientDecision = try await metalDecision(
            device: device,
            changedCoordinates: insufficientChange
        )
        let supportedDecision = try await metalDecision(
            device: device,
            changedCoordinates: spatialWindowCoordinates
        )
        XCTAssertFalse(insufficientDecision)
        XCTAssertTrue(supportedDecision)
    }

    func testMetalGateSpatiallyAggregatesWithinCells() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this host.")
        }
        let sparseCoordinates = spatialWindowCoordinates.map { coordinate in
            (x: coordinate.x * 30, y: coordinate.y * 30)
        }
        let sparseDecision = try await metalDecision(
            device: device,
            width: 1_920,
            height: 1_080,
            changedCoordinates: sparseCoordinates
        )
        XCTAssertFalse(sparseDecision)

        let changedRegions: [PixelRegion] = spatialWindowCoordinates.map { coordinate in
            (
                x: (coordinate.x * 30)..<((coordinate.x + 1) * 30),
                y: (coordinate.y * 30)..<((coordinate.y + 1) * 30)
            )
        }
        let regionDecision = try await metalDecision(
            device: device,
            width: 1_920,
            height: 1_080,
            changedRegions: changedRegions
        )
        XCTAssertTrue(regionDecision)
    }

    func testMetalGateKeepsReferenceUntilSpatialSupportIsDetected() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this host.")
        }
        let gate = BackgroundRemovalInferenceGate(metalDevice: device)
        let textureCache = try makeTextureCache(device: device)

        for (index, luma) in [UInt8(32), 38, 44].enumerated() {
            let pixelBuffer = try makePixelBuffer(width: 64, height: 36, luma: luma)
            let texture = try makeLumaTexture(
                pixelBuffer: pixelBuffer,
                textureCache: textureCache
            )
            XCTAssertEqual(gate.shouldRunInference(lumaTexture: texture), index == 0)
            try await waitForEvaluation(of: gate)
        }

        let stable = try makePixelBuffer(width: 64, height: 36, luma: 44)
        let stableTexture = try makeLumaTexture(pixelBuffer: stable, textureCache: textureCache)
        XCTAssertTrue(gate.shouldRunInference(lumaTexture: stableTexture))
    }

    private var spatialWindowCoordinates: [(x: Int, y: Int)] {
        [
            (10, 10), (11, 10), (12, 10), (13, 10),
            (10, 11), (11, 11), (12, 11), (13, 11)
        ]
    }

    private func metalDecision(
        device: MTLDevice,
        width: Int = 64,
        height: Int = 36,
        changedCoordinates: [(x: Int, y: Int)] = [],
        changedRegions: [PixelRegion] = []
    ) async throws -> Bool {
        let gate = BackgroundRemovalInferenceGate(metalDevice: device)
        let textureCache = try makeTextureCache(device: device)
        let first = try makePixelBuffer(width: width, height: height, luma: 32)
        let firstTexture = try makeLumaTexture(pixelBuffer: first, textureCache: textureCache)
        XCTAssertTrue(gate.shouldRunInference(lumaTexture: firstTexture))
        try await waitForEvaluation(of: gate)
        let second = try makePixelBuffer(
            width: width,
            height: height,
            luma: 32,
            changedCoordinates: changedCoordinates,
            changedRegions: changedRegions
        )
        let secondTexture = try makeLumaTexture(pixelBuffer: second, textureCache: textureCache)
        XCTAssertFalse(gate.shouldRunInference(lumaTexture: secondTexture))
        try await waitForEvaluation(of: gate)
        return gate.shouldRunInference(lumaTexture: secondTexture)
    }

    private func waitForEvaluation(
        of gate: BackgroundRemovalInferenceGate,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while gate.isEvaluationPending {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for the Metal gate evaluation.")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeTextureCache(device: MTLDevice) throws -> CVMetalTextureCache {
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard status == kCVReturnSuccess, let textureCache else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return textureCache
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        luma: UInt8,
        changedCoordinates: [(x: Int, y: Int)] = [],
        changedRegions: [PixelRegion] = []
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
        lumaBaseAddress.initializeMemory(
            as: UInt8.self,
            repeating: luma,
            count: lumaBytesPerRow * lumaHeight
        )
        let lumaBytes = lumaBaseAddress.assumingMemoryBound(to: UInt8.self)
        for coordinate in changedCoordinates {
            lumaBytes[coordinate.y * lumaBytesPerRow + coordinate.x] = 200
        }
        for region in changedRegions {
            for y in region.y {
                for x in region.x {
                    lumaBytes[y * lumaBytesPerRow + x] = 200
                }
            }
        }

        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
        chromaBaseAddress.initializeMemory(
            as: UInt8.self,
            repeating: 128,
            count: chromaBytesPerRow * chromaHeight
        )

        return pixelBuffer
    }

    private func makeLumaTexture(
        pixelBuffer: CVPixelBuffer,
        textureCache: CVMetalTextureCache
    ) throws -> MTLTexture {
        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Uint,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            0,
            &metalTexture
        )
        guard status == kCVReturnSuccess,
              let metalTexture,
              let texture = CVMetalTextureGetTexture(metalTexture) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return texture
    }
}
