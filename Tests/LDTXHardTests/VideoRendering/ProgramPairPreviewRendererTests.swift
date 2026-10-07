// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXVideoRendering
import Metal
import Testing

@Suite
struct ProgramPairPreviewRendererIntegrationTestSuite {
  @Test func directRegionRenderingPreservesNeighborsAndUsesBothChromaPlanes() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let pipeline = try VideoCompositor.makePreviewRegionPipeline(device: device)
    let queue = try #require(device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    func texture(_ format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format,
        width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = [.shaderRead, .shaderWrite]
      return try #require(device.makeTexture(descriptor: descriptor))
    }
    let y = try texture(.r8Uint, width: 2, height: 2)
    let uv = try texture(.rg8Uint, width: 1, height: 1)
    let blueUV = try texture(.rg8Uint, width: 1, height: 1)
    let blue: [UInt8] = [224, 64]
    blue.withUnsafeBytes {
      blueUV.replace(
        region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 2)
    }
    let output = try texture(.bgra8Unorm, width: 12, height: 4)
    let luma: [UInt8] = [128, 128, 128, 128]
    luma.withUnsafeBytes {
      y.replace(
        region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 2)
    }
    let chroma: [UInt8] = [64, 224]
    chroma.withUnsafeBytes {
      uv.replace(
        region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 2)
    }
    let sentinel = [UInt8](repeating: 17, count: 192)
    sentinel.withUnsafeBytes {
      output.replace(
        region: MTLRegionMake2D(0, 0, 12, 4), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 48)
    }
    let encoder = try #require(command.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(y, index: 0)
    encoder.setTexture(uv, index: 1)
    encoder.setTexture(output, index: 2)
    for (origin, stateValue) in [
      (1, UInt32(1)), (3, UInt32(1)), (5, UInt32(2)), (7, UInt32(0)), (9, UInt32(3)),
    ] {
      encoder.setTexture(origin == 3 ? blueUV : uv, index: 1)
      var region = SIMD4<UInt32>(UInt32(origin), 1, 2, 2)
      var state = stateValue
      encoder.setBytes(&region, length: 16, index: 0)
      encoder.setBytes(&state, length: 4, index: 1)
      encoder.dispatchThreads(
        MTLSize(width: 2, height: 2, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 2, height: 2, depth: 1))
    }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    #expect(command.status == .completed)
    var pixels = [UInt8](repeating: 0, count: 192)
    pixels.withUnsafeMutableBytes {
      output.getBytes(
        $0.baseAddress!, bytesPerRow: 48,
        from: MTLRegionMake2D(0, 0, 12, 4), mipmapLevel: 0)
    }
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
      Array(pixels[(y * 12 + x) * 4..<(y * 12 + x + 1) * 4])
    }
    #expect(pixel(0, 0) == [17, 17, 17, 17])
    #expect(pixel(3, 1)[0] > 240)
    #expect(pixel(3, 1)[2] < 40)
    #expect(pixel(1, 1)[2] > 240)  // Colored red, rather than luma-only gray.
    #expect(pixel(1, 1)[0] < 30)
    #expect(pixel(5, 1) == [64, 64, 64, 255])
    #expect(pixel(7, 1) == [0, 0, 0, 255])
    #expect(pixel(9, 1) == [128, 128, 128, 255])
    #expect(pixel(11, 3) == [17, 17, 17, 17])

    let pairOutput = try texture(.bgra8Unorm, width: 64, height: 32)
    let transparent = [UInt8](repeating: 0, count: 64 * 32 * 4)
    transparent.withUnsafeBytes {
      pairOutput.replace(
        region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
    }
    let pairRegions = ProgramPairPreviewRegions(
      drawable: CGSize(width: 64, height: 32),
      landscapeSize: CGSize(width: 16, height: 9),
      portraitSize: CGSize(width: 9, height: 16)
    )
    let pairCommand = try #require(queue.makeCommandBuffer())
    let pairEncoder = try #require(pairCommand.makeComputeCommandEncoder())
    pairEncoder.setComputePipelineState(pipeline)
    pairEncoder.setTexture(y, index: 0)
    pairEncoder.setTexture(uv, index: 1)
    pairEncoder.setTexture(pairOutput, index: 2)
    for rect in [pairRegions.landscape, pairRegions.portrait] {
      var region = SIMD4<UInt32>(
        UInt32(rect.minX), UInt32(rect.minY), UInt32(rect.width), UInt32(rect.height))
      var state = UInt32(1)
      pairEncoder.setBytes(&region, length: 16, index: 0)
      pairEncoder.setBytes(&state, length: 4, index: 1)
      pairEncoder.dispatchThreads(
        MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 4, depth: 1))
    }
    pairEncoder.endEncoding()
    pairCommand.commit()
    pairCommand.waitUntilCompleted()
    #expect(pairCommand.status == .completed)
    var pairPixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
    pairPixels.withUnsafeMutableBytes {
      pairOutput.getBytes(
        $0.baseAddress!, bytesPerRow: 64 * 4,
        from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
    }
    let gapPixelOffset = (16 * 64 + Int(pairRegions.gap.midX)) * 4
    #expect(pairPixels[gapPixelOffset + 3] == 0)
  }
}
