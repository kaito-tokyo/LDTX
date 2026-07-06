// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal

enum MetalShaderLibraryLoader {
    static func makeLibrary(
        device: MTLDevice,
        bundleToken: AnyClass,
        sourceResourceNames: [String]
    ) throws -> MTLLibrary {
        #if SWIFT_PACKAGE
        if let library = try? device.makeDefaultLibrary(bundle: .module) {
            return library
        }
        if let library = try makeSourceLibrary(device: device, resourceNames: sourceResourceNames) {
            return library
        }
        #else
        if let library = try? device.makeDefaultLibrary(bundle: Bundle(for: bundleToken)) {
            return library
        }
        #endif
        if let library = device.makeDefaultLibrary() {
            return library
        }
        throw VideoCompositorError.shaderCompilationFailed("The default Metal library was not found.")
    }

    #if SWIFT_PACKAGE
    private static func makeSourceLibrary(device: MTLDevice, resourceNames: [String]) throws -> MTLLibrary? {
        let sourceParts = try resourceNames.compactMap { resourceName -> String? in
            guard let sourceURL = Bundle.module.url(forResource: resourceName, withExtension: "metal") else {
                return nil
            }
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
        guard !sourceParts.isEmpty else {
            return nil
        }
        let source = sourceParts.joined(separator: "\n\n")
        return try device.makeLibrary(source: source, options: nil)
    }
    #endif
}
