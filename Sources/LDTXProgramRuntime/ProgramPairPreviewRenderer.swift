// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXVideoRendering
import Metal
import MetalKit

/// Renders two ProgramRuntime frames into a drawable supplied by the UI.
/// The owner provides the single MTKView; this object only acts as its delegate.
public final class ProgramPairPreviewRenderer: NSObject, MTKViewDelegate {
  private struct Configuration {
    var landscapeSize: CGSize
    var portraitSize: CGSize
    var prefersColor: Bool
  }

  private let lock = NSLock()
  private var configuration: Configuration
  private var isRunning = false
  private let landscapeRuntime: ProgramRuntime
  private let portraitRuntime: ProgramRuntime
  public let device = MTLCreateSystemDefaultDevice()
  private let commandQueue: MTLCommandQueue?
  private let pipeline: MTLComputePipelineState?
  private let textureCache: CVMetalTextureCache?
  private let emptyLuma: MTLTexture?
  private let emptyChroma: MTLTexture?

  public init(
    landscapeRuntime: ProgramRuntime,
    portraitRuntime: ProgramRuntime,
    landscapeSize: CGSize,
    portraitSize: CGSize,
    prefersColor: Bool
  ) {
    self.landscapeRuntime = landscapeRuntime
    self.portraitRuntime = portraitRuntime
    configuration = Configuration(
      landscapeSize: landscapeSize,
      portraitSize: portraitSize,
      prefersColor: prefersColor
    )
    commandQueue = device?.makeCommandQueue()
    pipeline = device.flatMap { try? VideoCompositor.makePreviewRegionPipeline(device: $0) }
    var cache: CVMetalTextureCache?
    if let device {
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }
    textureCache = cache
    emptyLuma = device?.makeTexture(
      descriptor: .texture2DDescriptor(
        pixelFormat: .r8Uint, width: 1, height: 1, mipmapped: false))
    emptyChroma = device?.makeTexture(
      descriptor: .texture2DDescriptor(
        pixelFormat: .rg8Uint, width: 1, height: 1, mipmapped: false))
    super.init()
  }

  public func update(
    landscapeSize: CGSize,
    portraitSize: CGSize,
    prefersColor: Bool
  ) {
    lock.withLock {
      configuration = Configuration(
        landscapeSize: landscapeSize,
        portraitSize: portraitSize,
        prefersColor: prefersColor
      )
    }
  }

  public func start() {
    let shouldStart = lock.withLock { () -> Bool in
      guard !isRunning else { return false }
      isRunning = true
      return true
    }
    guard shouldStart else { return }
    landscapeRuntime.startPreview()
    portraitRuntime.startPreview()
  }

  public func stop() {
    let shouldStop = lock.withLock { () -> Bool in
      guard isRunning else { return false }
      isRunning = false
      return true
    }
    guard shouldStop else { return }
    landscapeRuntime.stopPreview()
    portraitRuntime.stopPreview()
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  public func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
      let command = commandQueue?.makeCommandBuffer()
    else { return }

    let clearPass = MTLRenderPassDescriptor()
    clearPass.colorAttachments[0].texture = drawable.texture
    clearPass.colorAttachments[0].loadAction = .clear
    clearPass.colorAttachments[0].storeAction = .store
    clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    guard let clearEncoder = command.makeRenderCommandEncoder(descriptor: clearPass) else {
      return
    }
    clearEncoder.endEncoding()

    let configuration = lock.withLock { configuration }
    let frames = [landscapeRuntime.latestFrame(), portraitRuntime.latestFrame()]
    let regions = ProgramPairPreviewRegions(
      drawable: CGSize(width: drawable.texture.width, height: drawable.texture.height),
      landscapeSize: configuration.landscapeSize,
      portraitSize: configuration.portraitSize
    )
    let lease = ProgramPairFrameLease(frames: frames)

    if let pipeline, let emptyLuma, let emptyChroma,
      let encoder = command.makeComputeCommandEncoder()
    {
      encoder.setComputePipelineState(pipeline)
      encoder.setTexture(drawable.texture, index: 2)
      let rects = [regions.landscape, regions.portrait]
      for (frame, rect) in zip(frames, rects) {
        guard rect.width > 0, rect.height > 0 else { continue }
        var state: UInt32 = frame?.isPreparingRenderResources == true ? 2 : 0
        var luma = emptyLuma
        var chroma = emptyChroma
        if let frame, !frame.isPreparingRenderResources, let textureCache,
          let y = frame.makeCVMetalTexture(
            using: textureCache, pixelFormat: .r8Uint, planeIndex: 0),
          let yTexture = CVMetalTextureGetTexture(y)
        {
          lease.textures.append(y)
          luma = yTexture
          if !configuration.prefersColor {
            state = 3
          } else if let uv = frame.makeCVMetalTexture(
            using: textureCache, pixelFormat: .rg8Uint, planeIndex: 1),
            let uvTexture = CVMetalTextureGetTexture(uv)
          {
            lease.textures.append(uv)
            chroma = uvTexture
            state = 1
          }
        }
        var region = SIMD4<UInt32>(
          UInt32(rect.minX), UInt32(rect.minY), UInt32(rect.width), UInt32(rect.height))
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setBytes(&region, length: MemoryLayout.size(ofValue: region), index: 0)
        encoder.setBytes(&state, length: MemoryLayout.size(ofValue: state), index: 1)
        encoder.dispatchThreads(
          MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
          threadsPerThreadgroup: MTLSize(
            width: pipeline.threadExecutionWidth,
            height: max(1, pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth),
            depth: 1
          )
        )
      }
      encoder.endEncoding()
    }

    command.addCompletedHandler { _ in withExtendedLifetime(lease) {} }
    command.present(drawable)
    command.commit()
  }
}

/// Pixel-aligned equal-height regions with a transparent four-pixel gap.
public struct ProgramPairPreviewRegions {
  public let landscape: CGRect
  public let portrait: CGRect
  public let gap: CGRect

  public init(drawable: CGSize, landscapeSize: CGSize, portraitSize: CGSize) {
    let landscapeRatio = max(1, landscapeSize.width) / max(1, landscapeSize.height)
    let portraitRatio = max(1, portraitSize.width) / max(1, portraitSize.height)
    let gapWidth = min(4, max(0, floor(drawable.width)))
    let availableWidth = max(0, drawable.width - gapWidth)
    let height = floor(
      max(0, min(drawable.height, availableWidth / (landscapeRatio + portraitRatio))))
    let landscapeWidth = floor(height * landscapeRatio)
    let portraitWidth = floor(height * portraitRatio)
    let totalWidth = landscapeWidth + gapWidth + portraitWidth
    let x = floor((drawable.width - totalWidth) / 2)
    let y = floor((drawable.height - height) / 2)
    landscape = CGRect(x: x, y: y, width: landscapeWidth, height: height)
    gap = CGRect(x: x + landscapeWidth, y: y, width: gapWidth, height: height)
    portrait = CGRect(x: gap.maxX, y: y, width: portraitWidth, height: height)
  }
}

private final class ProgramPairFrameLease: @unchecked Sendable {
  let frames: [ProgramFrame?]
  var textures: [CVMetalTexture] = []

  init(frames: [ProgramFrame?]) {
    self.frames = frames
  }
}
