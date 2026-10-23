// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import LDTXInternalProtocols
import LDTXVideoComposition
import LDTXVideoRendering
import OSLog

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
  var colorRangeOverride: CameraInputColorRangeOverride = .unspecified
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
    private let normalizer: CapturedInputNormalizer
    private var normalizedFrames:
      [String: (source: CapturedVideoFrame, result: Result<CapturedVideoFrame, any Error>)] = [:]
    private var reportedFailures: Set<String> = []
    private var announcedFailures: Set<String> = []
    private var lastFailureDiagnostic: [String: TimeInterval] = [:]
    private static let logger = Logger(
      subsystem: "tokyo.kaito.ldtx", category: "CapturedInputNormalization")

    init(
      device: MTLDevice,
      textureCache: CVMetalTextureCache,
      backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil
    ) {
      self.device = device
      self.normalizer = CapturedInputNormalizer(device: device)
      self.textureCache = textureCache
      self.backgroundRemovalPreprocessorFactory = backgroundRemovalPreprocessorFactory
    }

    func reset() {
      id = UUID()
      specificationsByInputKey = [:]
      preprocessorsByInputKey = [:]
      normalizedFrames = [:]
      reportedFailures = []
      announcedFailures = []
      lastFailureDiagnostic = [:]
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
      guard let preprocessor = preprocessorsByInputKey[inputKey] else { return .unavailable }
      let result: Result<CapturedVideoFrame, any Error>
      if let cached = normalizedFrames[inputKey],
        cached.source.captureSessionID == frame.captureSessionID,
        cached.source.sequenceNumber == frame.sequenceNumber,
        cached.source.pixelBuffer === frame.pixelBuffer
      {
        result = cached.result
      } else {
        result = Result {
          try normalizer.normalize(
            frame,
            rangeOverride: specificationsByInputKey[inputKey]?.colorRangeOverride ?? .unspecified)
        }
        normalizedFrames[inputKey] = (frame, result)
      }
      switch result {
      case .success(let normalized):
        reportedFailures.remove(inputKey)
        if announcedFailures.remove(inputKey) != nil {
          Self.logger.notice(
            "Captured input conversion recovered input=\(inputKey, privacy: .private(mask: .hash))")
        }
        return preprocessor.process(normalized)
      case .failure(let error):
        let now = ProcessInfo.processInfo.systemUptime
        if reportedFailures.insert(inputKey).inserted,
          lastFailureDiagnostic[inputKey].map({ now - $0 >= 10 }) ?? true
        {
          lastFailureDiagnostic[inputKey] = now
          announcedFailures.insert(inputKey)
          Self.logger.error(
            "Captured input unavailable input=\(inputKey, privacy: .private(mask: .hash)) reason=\((error as NSError).domain, privacy: .private) code=\((error as NSError).code, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
          )
        }
        return .unavailable
      }
    }
  }

  struct VideoInputMetalTextures {
    let lumaMetalTexture: CVMetalTexture
    let chromaMetalTexture: CVMetalTexture

    init(pixelBuffer: CVPixelBuffer, textureCache: CVMetalTextureCache) throws {
      let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
      guard
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      else { throw VideoCompositorError.unsupportedPixelBufferFormat(format) }
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

    func makeSource(
      from input: PreparedVideoInput,
      contentKind: VideoFrameContentKind = .captured
    ) -> MetalVideoSource {
      return .nv12Textures(
        pixelBuffer: input.frame.pixelBuffer,
        lumaMetalTexture: lumaMetalTexture,
        chromaMetalTexture: chromaMetalTexture,
        alphaTexture: input.alphaTexture,
        alphaMaskKind: input.alphaMaskKind,
        contentKind: contentKind
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
