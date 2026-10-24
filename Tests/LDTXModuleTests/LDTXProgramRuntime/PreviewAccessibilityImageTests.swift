// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
@testable import LDTXProgramRuntime
import Metal
import Testing

@Suite(.tags(.hard)) struct PreviewAccessibilityImageIntegrationTestSuite {
  @Test("LUB-1058: Return current preview pixels through accessibility image data")
  func gpuReadbackAndAXPixels() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let commandQueue = try #require(device.makeCommandQueue())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 2, height: 2, mipmapped: false)
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    // Top row red/green, bottom row blue/half-alpha red (premultiplied BGRA).
    let pixels: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 0, 128, 128]
    pixels.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 8)
    }
    let store = PreviewAccessibilityImageStore()
    #expect(store.data(for: ["AXImageDataFormat": "RGBA"]) == nil)
    store.update(texture: texture, commandQueue: commandQueue)
    #expect(store.size == CGSize(width: 2, height: 2))
    let full = try #require(store.data(for: ["AXImageDataFormat": "RGBA"]))
    #expect(Array(full) == [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 0, 0, 128])
    let cropped = try #require(
      store.data(for: [
        "AXImageDataFormat": "RGBA",
        "AXImageDataLeft": 1, "AXImageDataTop": 1, "AXImageDataWidth": 2, "AXImageDataHeight": 2,
      ]))
    #expect(Array(cropped) == [255, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    #expect(store.data(for: ["AXImageDataFormat": "PNG"]) == nil)
    for value: NSNumber in [-1, 1.5, .init(value: Double.nan), 16385, true] {
      #expect(
        store.data(for: ["AXImageDataFormat": "RGBA", "AXImageDataResizeWidth": value]) == nil)
    }
    #expect(
      store.data(for: [
        "AXImageDataFormat": "RGBA", "AXImageDataWidth": 16384,
        "AXImageDataHeight": 16384,
      ]) == nil)
    #expect(
      store.data(for: [
        "AXImageDataFormat": "RGBA", "AXImageDataResizeWidth": 4,
        "AXImageDataResizeHeight": 4,
      ])?.count == 64)
    #expect(
      store.data(for: [
        "AXImageDataFormat": "RGBA", "AXImageDataResizeWidth": 16384,
        "AXImageDataResizeHeight": 16384,
      ])?.count == 4_000_000 * 4)
    store.clear()
    #expect(store.size == .zero)
    #expect(store.data(for: ["AXImageDataFormat": "RGBA"]) == nil)
  }

  @Test("LUB-1058: Size queries do not read pixels and each image request reads current pixels")
  func sizeQueriesDoNotReadPixelsAndEachImageRequestReadsCurrentPixels() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let store = PreviewAccessibilityImageStore()
    store.update(texture: texture, commandQueue: queue)
    #expect(store.size == CGSize(width: 1, height: 1))
    // Mutate after publishing the source and querying its size. Only AXImageData
    // should sample it, and later requests must not return an earlier CPU snapshot.
    for bgra: [UInt8] in [[0, 0, 255, 255], [255, 0, 0, 255]] {
      bgra.withUnsafeBytes {
        texture.replace(
          region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
          withBytes: $0.baseAddress!, bytesPerRow: 4)
      }
      let data = try #require(store.data(for: ["AXImageDataFormat": "RGBA"]))
      #expect(Array(data) == [bgra[2], bgra[1], bgra[0], bgra[3]])
    }
  }
}
