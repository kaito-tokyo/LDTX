// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import LDTXBackgroundSegmentation
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
  final class BackgroundRemovalVideoInputPreprocessor: VideoInputPreprocessing, @unchecked Sendable
  {
    private enum ModelState {
      case idle
      case preparing
      case ready(MediaPipeSelfieSegmentationModel)
      case failed
    }

    private static let rawMaskTextureCount = 3
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let stateLock = NSLock()
    private var modelState: ModelState = .idle
    private var inferenceGate: BackgroundRemovalInferenceGate
    private var rawMaskTextures: [MTLTexture] = []
    private var nextRawMaskTextureIndex = 0
    private var lastEvaluatedSequenceNumber: UInt64?
    private var lastMaskTexture: MTLTexture?

    init(device: MTLDevice, textureCache: CVMetalTextureCache) {
      self.device = device
      self.textureCache = textureCache
      inferenceGate = BackgroundRemovalInferenceGate(metalDevice: device)
    }

    func process(_ frame: CapturedVideoFrame) -> VideoInputPreprocessingResult {
      let model: MediaPipeSelfieSegmentationModel
      switch stateLock.withLock({ modelState }) {
      case .idle:
        beginPreparingModel(for: frame.pixelBuffer)
        return .preparing
      case .preparing:
        return .preparing
      case .failed:
        return .unavailable
      case .ready(let readyModel):
        model = readyModel
      }

      guard
        let inputTextures = try? VideoInputMetalTextures(
          pixelBuffer: frame.pixelBuffer,
          textureCache: textureCache
        )
      else {
        return .unavailable
      }

      if lastEvaluatedSequenceNumber != frame.sequenceNumber || lastMaskTexture == nil {
        let shouldRunInference = inferenceGate.shouldRunInference(
          lumaTexture: inputTextures.lumaTexture,
          force: lastMaskTexture == nil
        )
        lastEvaluatedSequenceNumber = frame.sequenceNumber
        if shouldRunInference,
          let maskTexture = nextMaskTexture(),
          let lumaTexture = inputTextures.lumaTexture,
          let chromaTexture = inputTextures.chromaTexture,
          model.renderRawMaskTexture(
            frame.pixelBuffer,
            lumaTexture: lumaTexture,
            chromaTexture: chromaTexture,
            to: maskTexture
          )
        {
          lastMaskTexture = maskTexture
        }
      }

      guard let lastMaskTexture else {
        return .unavailable
      }
      return .ready(
        PreparedVideoInput(
          frame: frame,
          alphaTexture: lastMaskTexture,
          alphaMaskKind: .rawFloat16
        ))
    }

    private func beginPreparingModel(for pixelBuffer: CVPixelBuffer) {
      let shouldStart = stateLock.withLock { () -> Bool in
        guard case .idle = modelState else { return false }
        modelState = .preparing
        return true
      }
      guard shouldStart else { return }
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      let device = device
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let result = Result {
          try MediaPipeSelfieSegmentationModel(
            modelURL: BackgroundRemovalModelResource.modelURL(),
            sourceWidth: width,
            sourceHeight: height,
            metalDevice: device
          )
        }
        self?.stateLock.withLock {
          switch result {
          case .success(let model): self?.modelState = .ready(model)
          case .failure: self?.modelState = .failed
          }
        }
      }
    }

    private func nextMaskTexture() -> MTLTexture? {
      if rawMaskTextures.isEmpty {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .r16Float,
          width: MediaPipeSelfieSegmentationModel.rawMaskWidth,
          height: MediaPipeSelfieSegmentationModel.rawMaskHeight,
          mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        rawMaskTextures = (0..<Self.rawMaskTextureCount).compactMap { _ in
          device.makeTexture(descriptor: descriptor)
        }
        guard rawMaskTextures.count == Self.rawMaskTextureCount else {
          rawMaskTextures = []
          return nil
        }
      }
      let texture = rawMaskTextures[nextRawMaskTextureIndex]
      nextRawMaskTextureIndex = (nextRawMaskTextureIndex + 1) % rawMaskTextures.count
      return texture
    }
  }

  final class VideoInputPreprocessingPipeline {
    private(set) var id = UUID()
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private var specificationsByInputKey: [String: VideoInputPipelineSpecification] = [:]
    private var preprocessorsByInputKey: [String: any VideoInputPreprocessing] = [:]

    init(device: MTLDevice, textureCache: CVMetalTextureCache) {
      self.device = device
      self.textureCache = textureCache
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
            BackgroundRemovalVideoInputPreprocessor(
              device: device,
              textureCache: textureCache
            )
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
