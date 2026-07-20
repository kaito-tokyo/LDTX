// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import LDTXInternalProtocols
import LDTXVideoComposition
import LDTXVideoRendering

#if canImport(Metal)
  import Metal
#endif

enum VideoInputPreprocessingMode: Hashable, Sendable {
  case passthrough
  case backgroundRemoval
}

struct VideoInputPipelineSpecification: Hashable, Sendable {
  var cameraID: String
  var captureSessionID: UUID?
  var mode: VideoInputPreprocessingMode
}

struct PreparedVideoInput {
  var frame: CapturedVideoFrame
  #if canImport(Metal)
    var alphaTexture: MTLTexture?
    var alphaMaskKind: MetalVideoAlphaMaskKind?

    init(
      frame: CapturedVideoFrame,
      alphaTexture: MTLTexture? = nil,
      alphaMaskKind: MetalVideoAlphaMaskKind? = nil
    ) {
      self.frame = frame
      self.alphaTexture = alphaTexture
      self.alphaMaskKind = alphaMaskKind
    }
  #else
    init(frame: CapturedVideoFrame) {
      self.frame = frame
    }
  #endif
}

enum VideoInputPreprocessingResult {
  case ready(PreparedVideoInput)
  case preparing
  case unavailable
}

protocol VideoInputPreprocessing: AnyObject {
  func process(_ frame: CapturedVideoFrame) -> VideoInputPreprocessingResult
}

final class PassthroughVideoInputPreprocessor: VideoInputPreprocessing {
  func process(_ frame: CapturedVideoFrame) -> VideoInputPreprocessingResult {
    .ready(PreparedVideoInput(frame: frame))
  }
}

#if canImport(Metal)
  final class BackgroundRemovalVideoInputPreprocessorAdapter: VideoInputPreprocessing {
    private let implementation: any BackgroundRemovalPreprocessing

    init(implementation: any BackgroundRemovalPreprocessing) {
      self.implementation = implementation
    }

    func process(_ frame: CapturedVideoFrame) -> VideoInputPreprocessingResult {
      switch implementation.process(
        pixelBuffer: frame.pixelBuffer,
        sequenceNumber: frame.sequenceNumber
      ) {
      case .ready(let alphaTexture):
        .ready(
          PreparedVideoInput(
            frame: frame,
            alphaTexture: alphaTexture,
            alphaMaskKind: .rawFloat16
          ))
      case .preparing:
        .preparing
      case .unavailable:
        .unavailable
      }
    }
  }

  final class VideoInputPreprocessingPipeline {
    private(set) var id = UUID()
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?
    private var specificationsByInputKey: [String: VideoInputPipelineSpecification] = [:]
    private var preprocessorsByInputKey: [String: any VideoInputPreprocessing] = [:]

    init(
      device: MTLDevice,
      textureCache: CVMetalTextureCache,
      backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil
    ) {
      self.device = device
      self.textureCache = textureCache
      self.backgroundRemovalPreprocessorFactory = backgroundRemovalPreprocessorFactory
    }

    func reset() {
      id = UUID()
      specificationsByInputKey = [:]
      preprocessorsByInputKey = [:]
    }

    @discardableResult
    func synchronize(specifications: [String: VideoInputPipelineSpecification]) -> Bool {
      guard specifications != specificationsByInputKey else { return false }
      reset()
      specificationsByInputKey = specifications
      for (inputKey, specification) in specifications {
        preprocessorsByInputKey[inputKey] =
          switch specification.mode {
          case .passthrough:
            PassthroughVideoInputPreprocessor()
          case .backgroundRemoval:
            if let backgroundRemovalPreprocessorFactory {
              BackgroundRemovalVideoInputPreprocessorAdapter(
                implementation: backgroundRemovalPreprocessorFactory(device, textureCache)
              )
            } else {
              PassthroughVideoInputPreprocessor()
            }
          }
      }
      return true
    }

    func process(
      _ frame: CapturedVideoFrame,
      forInputKey inputKey: String
    ) -> VideoInputPreprocessingResult {
      preprocessorsByInputKey[inputKey]?.process(frame) ?? .unavailable
    }
  }

  struct VideoInputMetalTextures {
    let lumaMetalTexture: CVMetalTexture
    let chromaMetalTexture: CVMetalTexture

    init(pixelBuffer: CVPixelBuffer, textureCache: CVMetalTextureCache) throws {
      lumaMetalTexture = try Self.makeTexture(
        pixelBuffer,
        textureCache: textureCache,
        pixelFormat: .r8Uint,
        planeIndex: 0
      )
      chromaMetalTexture = try Self.makeTexture(
        pixelBuffer,
        textureCache: textureCache,
        pixelFormat: .rg8Uint,
        planeIndex: 1
      )
    }

    var lumaTexture: MTLTexture? { CVMetalTextureGetTexture(lumaMetalTexture) }
    var chromaTexture: MTLTexture? { CVMetalTextureGetTexture(chromaMetalTexture) }

    func makeSource(from input: PreparedVideoInput) -> MetalVideoSource {
      .nv12Textures(
        pixelBuffer: input.frame.pixelBuffer,
        lumaMetalTexture: lumaMetalTexture,
        chromaMetalTexture: chromaMetalTexture,
        alphaTexture: input.alphaTexture,
        alphaMaskKind: input.alphaMaskKind
      )
    }

    private static func makeTexture(
      _ pixelBuffer: CVPixelBuffer,
      textureCache: CVMetalTextureCache,
      pixelFormat: MTLPixelFormat,
      planeIndex: Int
    ) throws -> CVMetalTexture {
      guard CVPixelBufferGetPlaneCount(pixelBuffer) > planeIndex else {
        throw VideoCompositorError.unsupportedPixelBufferFormat(
          CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
      }
      var metalTexture: CVMetalTexture?
      let status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        textureCache,
        pixelBuffer,
        nil,
        pixelFormat,
        CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex),
        CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex),
        planeIndex,
        &metalTexture
      )
      guard status == kCVReturnSuccess, let metalTexture else {
        throw VideoCompositorError.textureCreationFailed(status)
      }
      return metalTexture
    }
  }
#endif
