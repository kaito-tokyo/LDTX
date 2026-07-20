// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Metal

/// The result of applying the optional background-removal preprocessing step.
public enum BackgroundRemovalPreprocessingResult {
  case ready(alphaTexture: any MTLTexture)
  case preparing
  case unavailable
}

/// Internal contract implemented by the optional background-segmentation module.
public protocol BackgroundRemovalPreprocessing: AnyObject {
  func process(
    pixelBuffer: CVPixelBuffer,
    sequenceNumber: UInt64
  ) -> BackgroundRemovalPreprocessingResult
}

/// Creates the single optional preprocessor used for a video input.
public typealias BackgroundRemovalPreprocessorFactory = (
  _ device: any MTLDevice,
  _ textureCache: CVMetalTextureCache
) -> any BackgroundRemovalPreprocessing
