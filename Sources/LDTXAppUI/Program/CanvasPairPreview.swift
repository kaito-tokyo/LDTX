// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXProgramRuntime
import LDTXVideoRendering
import MetalKit
import SwiftUI

struct CanvasPairPreview: View {
  @State private var prefersColor = true
  @StateObject private var landscape: ProgramPreviewController
  @StateObject private var portrait: ProgramPreviewController
  var landscapeSize: CGSize
  var portraitSize: CGSize

  init(
    landscapeRuntime: ProgramRuntime, portraitRuntime: ProgramRuntime,
    landscapeSize: CGSize, portraitSize: CGSize
  ) {
    _landscape = StateObject(
      wrappedValue: ProgramPreviewController(programRuntime: landscapeRuntime))
    _portrait = StateObject(wrappedValue: ProgramPreviewController(programRuntime: portraitRuntime))
    self.landscapeSize = landscapeSize
    self.portraitSize = portraitSize
  }

  var body: some View {
    CanvasPairMetalView(
      landscape: landscape, portrait: portrait,
      landscapeSize: landscapeSize, portraitSize: portraitSize, prefersColor: prefersColor
    )
    .aspectRatio(
      landscapeSize.width / max(1, landscapeSize.height)
        + portraitSize.width / max(1, portraitSize.height), contentMode: .fit
    )
    .contentShape(Rectangle())
    .onTapGesture { prefersColor.toggle() }
    .accessibilityValue(prefersColor ? "Accurate" : "Lightweight")
    .accessibilityAction { prefersColor.toggle() }
    .accessibilityLabel("Canvas Preview")
    .accessibilityIdentifier("canvasPairPreview")
  }
}

/// Pixel-aligned regions with equal heights, centered inside the actual drawable.
struct CanvasPairRegions {
  let landscape: CGRect
  let portrait: CGRect

  init(drawable: CGSize, landscapeSize: CGSize, portraitSize: CGSize) {
    let leftRatio = max(1, landscapeSize.width) / max(1, landscapeSize.height)
    let rightRatio = max(1, portraitSize.width) / max(1, portraitSize.height)
    let height = floor(max(0, min(drawable.height, drawable.width / (leftRatio + rightRatio))))
    let leftWidth = floor(height * leftRatio)
    let rightWidth = floor(height * rightRatio)
    let x = floor((drawable.width - leftWidth - rightWidth) / 2)
    let y = floor((drawable.height - height) / 2)
    landscape = CGRect(x: x, y: y, width: leftWidth, height: height)
    portrait = CGRect(x: x + leftWidth, y: y, width: rightWidth, height: height)
  }
}

private struct CanvasPairMetalView: NSViewRepresentable {
  let landscape: ProgramPreviewController
  let portrait: ProgramPreviewController
  var landscapeSize: CGSize
  var portraitSize: CGSize
  var prefersColor: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      landscape: landscape, portrait: portrait,
      landscapeSize: landscapeSize, portraitSize: portraitSize)
  }

  func makeNSView(context: Context) -> MTKView {
    let view = ProgramPreviewMTKView(frame: .zero, device: context.coordinator.device)
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = false
    view.autoResizeDrawable = false
    view.preferredFramesPerSecond = 15
    view.clearColor = MTLClearColorMake(0, 0, 0, 1)
    view.delegate = context.coordinator
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.image)
    view.setAccessibilityLabel("Landscape and Portrait preview")
    view.setAccessibilityIdentifier("canvasPairPreview")
    landscape.setPreferredFrameRate(15)
    portrait.setPreferredFrameRate(15)
    landscape.start()
    portrait.start()
    return view
  }

  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.prefersColor = prefersColor
    context.coordinator.landscapeSize = landscapeSize
    context.coordinator.portraitSize = portraitSize
  }

  static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
    view.isPaused = true
    view.delegate = nil
    coordinator.landscape.stop()
    coordinator.portrait.stop()
  }

  final class Coordinator: NSObject, MTKViewDelegate {
    var prefersColor = true
    let device = MTLCreateSystemDefaultDevice()
    let landscape: ProgramPreviewController
    let portrait: ProgramPreviewController
    var landscapeSize: CGSize
    var portraitSize: CGSize
    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private let textureCache: CVMetalTextureCache?
    private let emptyLuma: MTLTexture?
    private let emptyChroma: MTLTexture?

    init(
      landscape: ProgramPreviewController, portrait: ProgramPreviewController,
      landscapeSize: CGSize, portraitSize: CGSize
    ) {
      self.landscape = landscape
      self.portrait = portrait
      self.landscapeSize = landscapeSize
      self.portraitSize = portraitSize
      queue = device?.makeCommandQueue()
      pipeline = device.flatMap { try? VideoCompositor.makePreviewRegionPipeline(device: $0) }
      var cache: CVMetalTextureCache?
      if let device { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
      textureCache = cache
      emptyLuma = device?.makeTexture(
        descriptor: .texture2DDescriptor(
          pixelFormat: .r8Uint, width: 1, height: 1, mipmapped: false))
      emptyChroma = device?.makeTexture(
        descriptor: .texture2DDescriptor(
          pixelFormat: .rg8Uint, width: 1, height: 1, mipmapped: false))
      super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      guard let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer() else {
        return
      }
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = drawable.texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
      command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
      let frames = [landscape.latestFrame(), portrait.latestFrame()]
      let regions = CanvasPairRegions(
        drawable: CGSize(width: drawable.texture.width, height: drawable.texture.height),
        landscapeSize: landscapeSize, portraitSize: portraitSize)
      let lease = FrameLease(frames: frames)
      if let pipeline, let emptyLuma, let emptyChroma,
        let encoder = command.makeComputeCommandEncoder()
      {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(drawable.texture, index: 2)
        for (frame, rect) in zip(frames, [regions.landscape, regions.portrait]) {
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
            // Shader states: 0 missing, 1 accurate, 2 preparing, 3 lightweight.
            if !prefersColor {
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
            UInt32(rect.minX), UInt32(rect.minY),
            UInt32(rect.width), UInt32(rect.height))
          encoder.setTexture(luma, index: 0)
          encoder.setTexture(chroma, index: 1)
          encoder.setBytes(&region, length: MemoryLayout.size(ofValue: region), index: 0)
          encoder.setBytes(&state, length: MemoryLayout.size(ofValue: state), index: 1)
          encoder.dispatchThreads(
            MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
            threadsPerThreadgroup: MTLSize(
              width: pipeline.threadExecutionWidth,
              height: max(
                1, pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth), depth: 1
            ))
        }
        encoder.endEncoding()
      }
      // Keep the source pixel buffers alive until Metal has finished reading them.
      command.addCompletedHandler { _ in withExtendedLifetime(lease) {} }
      command.present(drawable)
      command.commit()
    }
  }
}

// CoreVideo texture wrappers must outlive GPU reads, as must their source buffers.
private final class FrameLease: @unchecked Sendable {
  let frames: [ProgramFrame?]
  var textures: [CVMetalTexture] = []
  init(frames: [ProgramFrame?]) { self.frames = frames }
}
