// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum BackgroundRemovalModelResource {
    public enum Error: Swift.Error, LocalizedError {
        case notFound

        public var errorDescription: String? {
            "MediaPipeSelfieSegmenter Core ML model was not found in the app bundle."
        }
    }

    public static func modelURL(bundle: Bundle = .main) throws -> URL {
        if let compiledURL = bundle.url(forResource: "MediaPipeSelfieSegmenter", withExtension: "mlmodelc") {
            return compiledURL
        }
        if let packageURL = bundle.url(forResource: "MediaPipeSelfieSegmenter", withExtension: "mlpackage") {
            return packageURL
        }
        throw Error.notFound
    }
}
