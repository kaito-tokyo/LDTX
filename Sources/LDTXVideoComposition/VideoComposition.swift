// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import simd

#if canImport(Metal)
  import Metal
#endif

public enum MetalVideoComponentCommand {
  case solidColor(SolidColorComponent)
  case linearGradient(LinearGradientComponent)
  case radialGradient(RadialGradientComponent)
  case conicGradient(ConicGradientComponent)
  case cameraInput(CameraInputComponent)
  #if canImport(Metal)
    case retainedTexture(RetainedTextureComponent)
  #endif
  case testPattern(TestPatternComponent)
}

public enum VideoFrameContentKind: Hashable, Sendable {
  case captured
  case dummy
}

public enum MetalVideoSource {
  #if canImport(Metal)
    case nv12Textures(
      pixelBuffer: CVPixelBuffer,
      lumaMetalTexture: CVMetalTexture,
      chromaMetalTexture: CVMetalTexture,
      alphaTexture: MTLTexture?,
      alphaMaskKind: MetalVideoAlphaMaskKind?,
      contentKind: VideoFrameContentKind
    )
  #endif
}

#if canImport(Metal)
  extension MetalVideoSource {
    public var contentKind: VideoFrameContentKind {
      switch self {
      case .nv12Textures(_, _, _, _, _, let contentKind):
        contentKind
      }
    }

    public var hasAlphaMask: Bool {
      switch self {
      case .nv12Textures(_, _, _, let alphaTexture, _, _):
        alphaTexture != nil
      }
    }
  }
#endif

#if canImport(Metal)
  public enum MetalVideoAlphaMaskKind: Hashable, Sendable {
    case oneComponent8
    case rawFloat16
  }
#endif

public protocol MetalVideoComponent {
  func makeCommand() -> MetalVideoComponentCommand
}

public struct SolidColorComponent: MetalVideoComponent {
  public var color: SIMD4<Float>
  public var destinationRect: SIMD4<UInt32>
  public var opacity: Float

  public init(
    color: SIMD4<Float>,
    destinationRect: SIMD4<UInt32>,
    opacity: Float = 1
  ) {
    self.color = color
    self.destinationRect = destinationRect
    self.opacity = opacity
  }

  public func makeCommand() -> MetalVideoComponentCommand {
    .solidColor(self)
  }
}

public struct LinearGradientComponent: MetalVideoComponent {
  public var start: SIMD2<Float>
  public var end: SIMD2<Float>
  public var startColor: SIMD4<Float>
  public var endColor: SIMD4<Float>
  public var destinationRect: SIMD4<UInt32>

  public init(
    start: SIMD2<Float>,
    end: SIMD2<Float>,
    startColor: SIMD4<Float>,
    endColor: SIMD4<Float>,
    destinationRect: SIMD4<UInt32>
  ) {
    self.start = start
    self.end = end
    self.startColor = startColor
    self.endColor = endColor
    self.destinationRect = destinationRect
  }

  public func makeCommand() -> MetalVideoComponentCommand {
    .linearGradient(self)
  }
}

public struct RadialGradientComponent: MetalVideoComponent {
  public var center: SIMD2<Float>
  public var innerRadius: Float
  public var outerRadius: Float
  public var innerColor: SIMD4<Float>
  public var outerColor: SIMD4<Float>
  public var destinationRect: SIMD4<UInt32>
  public var destinationToSource: simd_float4x4
  public var opacity: Float

  public init(
    center: SIMD2<Float>,
    innerRadius: Float = 0,
    outerRadius: Float,
    innerColor: SIMD4<Float>,
    outerColor: SIMD4<Float>,
    destinationRect: SIMD4<UInt32>,
    destinationToSource: simd_float4x4 = matrix_identity_float4x4,
    opacity: Float = 1
  ) {
    self.center = center
    self.innerRadius = innerRadius
    self.outerRadius = outerRadius
    self.innerColor = innerColor
    self.outerColor = outerColor
    self.destinationRect = destinationRect
    self.destinationToSource = destinationToSource
    self.opacity = opacity
  }

  public func makeCommand() -> MetalVideoComponentCommand {
    .radialGradient(self)
  }
}

public struct ConicGradientComponent: MetalVideoComponent {
  public var center: SIMD2<Float>
  public var startAngleRadians: Float
  public var startColor: SIMD4<Float>
  public var endColor: SIMD4<Float>
  public var destinationRect: SIMD4<UInt32>
  public var destinationToSource: simd_float4x4
  public var opacity: Float

  public init(
    center: SIMD2<Float>,
    startAngleRadians: Float = 0,
    startColor: SIMD4<Float>,
    endColor: SIMD4<Float>,
    destinationRect: SIMD4<UInt32>,
    destinationToSource: simd_float4x4 = matrix_identity_float4x4,
    opacity: Float = 1
  ) {
    self.center = center
    self.startAngleRadians = startAngleRadians
    self.startColor = startColor
    self.endColor = endColor
    self.destinationRect = destinationRect
    self.destinationToSource = destinationToSource
    self.opacity = opacity
  }

  public func makeCommand() -> MetalVideoComponentCommand {
    .conicGradient(self)
  }
}

public struct CameraInputComponent: MetalVideoComponent {
  public var source: MetalVideoSource
  public var destinationRect: SIMD4<UInt32>
  public var sourceRect: SIMD4<Float>
  public var colorRangeOverride: CameraInputColorRangeOverride

  public init(
    source: MetalVideoSource,
    destinationRect: SIMD4<UInt32>,
    sourceRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
    colorRangeOverride: CameraInputColorRangeOverride = .unspecified
  ) {
    self.source = source
    self.destinationRect = destinationRect
    self.sourceRect = sourceRect
    self.colorRangeOverride = colorRangeOverride
  }

  public func makeCommand() -> MetalVideoComponentCommand {
    .cameraInput(self)
  }
}

#if canImport(Metal)
  /// A retained standard-texture overlay sampled by the integer NV12 compositor.
  public struct RetainedTextureComponent: MetalVideoComponent {
    public var colorTexture: MTLTexture
    public var alphaTexture: MTLTexture?
    public var destinationRect: SIMD4<UInt32>
    public var sourceRect: SIMD4<Float>

    public init(
      colorTexture: MTLTexture,
      alphaTexture: MTLTexture? = nil,
      destinationRect: SIMD4<UInt32>,
      sourceRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1)
    ) {
      self.colorTexture = colorTexture
      self.alphaTexture = alphaTexture
      self.destinationRect = destinationRect
      self.sourceRect = sourceRect
    }

    public func makeCommand() -> MetalVideoComponentCommand {
      .retainedTexture(self)
    }
  }
#endif

public enum CameraInputColorRangeOverride: String, Codable, Equatable, Sendable {
  case unspecified
  case videoRange
  case fullRange
}

public struct TestPatternComponent: MetalVideoComponent {
  public var timeSeconds: Float
  public var destinationRect: SIMD4<UInt32>

  public init(
    timeSeconds: Float,
    destinationRect: SIMD4<UInt32>
  ) {
    self.timeSeconds = timeSeconds
    self.destinationRect = destinationRect
  }

  public func makeCommand() -> MetalVideoComponentCommand {
    .testPattern(self)
  }
}
