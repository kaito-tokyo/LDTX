// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum BackgroundRemovalModelResource {
  enum Error: Swift.Error, LocalizedError {
    case modelNotFound

    var errorDescription: String? {
      "MediaPipeSelfieSegmenter Core ML model was not found in the app bundle."
    }
  }

  static func modelURL(bundle: Bundle = .main) throws -> URL {
    if let compiledURL = bundle.url(
      forResource: "MediaPipeSelfieSegmenter",
      withExtension: "mlmodelc"
    ) {
      return compiledURL
    }
    if let packageURL = bundle.url(
      forResource: "MediaPipeSelfieSegmenter",
      withExtension: "mlpackage"
    ) {
      return packageURL
    }
    throw Error.modelNotFound
  }
}
