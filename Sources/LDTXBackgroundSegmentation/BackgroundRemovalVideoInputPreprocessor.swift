// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import LDTXInternalProtocols
import Metal

public final class BackgroundRemovalVideoInputPreprocessor:
  BackgroundRemovalPreprocessing, @unchecked Sendable
{
  private enum ModelState {
    case idle
    case preparing
    case ready(MediaPipeSelfieSegmentationModel)
    case failed
  }

  private static let rawMaskTextureCount = 3
  private let device: any MTLDevice
  private let textureCache: CVMetalTextureCache
  private let stateLock = NSLock()
  private var modelState: ModelState = .idle
  private var inferenceGate: BackgroundRemovalInferenceGate
  private var rawMaskTextures: [any MTLTexture] = []
  private var nextRawMaskTextureIndex = 0
  private var lastEvaluatedSequenceNumber: UInt64?
  private var lastMaskTexture: (any MTLTexture)?

  public init(device: any MTLDevice, textureCache: CVMetalTextureCache) {
    self.device = device
    self.textureCache = textureCache
    inferenceGate = BackgroundRemovalInferenceGate(metalDevice: device)
  }

  public func process(
    pixelBuffer: CVPixelBuffer,
    sequenceNumber: UInt64
  ) -> BackgroundRemovalPreprocessingResult {
    let model: MediaPipeSelfieSegmentationModel
    switch stateLock.withLock({ modelState }) {
    case .idle:
      beginPreparingModel(for: pixelBuffer)
      return .preparing
    case .preparing:
      return .preparing
    case .failed:
      return .unavailable
    case .ready(let readyModel):
      model = readyModel
    }

    guard let inputTextures = try? InputMetalTextures(
      pixelBuffer: pixelBuffer,
      textureCache: textureCache
    ) else {
      return .unavailable
    }

    if lastEvaluatedSequenceNumber != sequenceNumber || lastMaskTexture == nil {
      let shouldRunInference = inferenceGate.shouldRunInference(
        lumaTexture: inputTextures.lumaTexture,
        force: lastMaskTexture == nil
      )
      lastEvaluatedSequenceNumber = sequenceNumber
      if shouldRunInference,
        let maskTexture = nextMaskTexture(),
        let lumaTexture = inputTextures.lumaTexture,
        let chromaTexture = inputTextures.chromaTexture,
        model.renderRawMaskTexture(
          pixelBuffer,
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
    return .ready(alphaTexture: lastMaskTexture)
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

  private func nextMaskTexture() -> (any MTLTexture)? {
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

private struct InputMetalTextures {
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

  var lumaTexture: (any MTLTexture)? { CVMetalTextureGetTexture(lumaMetalTexture) }
  var chromaTexture: (any MTLTexture)? { CVMetalTextureGetTexture(chromaMetalTexture) }

  private static func makeTexture(
    _ pixelBuffer: CVPixelBuffer,
    textureCache: CVMetalTextureCache,
    pixelFormat: MTLPixelFormat,
    planeIndex: Int
  ) throws -> CVMetalTexture {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) > planeIndex else {
      throw InputMetalTextureError.unsupportedPixelBufferFormat
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
      throw InputMetalTextureError.textureCreationFailed(status)
    }
    return metalTexture
  }
}

private enum InputMetalTextureError: Error {
  case unsupportedPixelBufferFormat
  case textureCreationFailed(CVReturn)
}
