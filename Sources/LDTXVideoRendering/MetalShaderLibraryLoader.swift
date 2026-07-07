// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal

enum MetalShaderLibraryLoader {
    static func makeLibrary(
        device: MTLDevice,
        bundleToken: AnyClass
    ) throws -> MTLLibrary {
        let bundle = shaderBundle(bundleToken: bundleToken)

        if let bundle,
           let library = try? device.makeDefaultLibrary(bundle: bundle) {
            return library
        }

        if let bundle,
           let library = try makeLibraryFromSource(device: device, bundle: bundle) {
            return library
        }

        if let library = device.makeDefaultLibrary() {
            return library
        }

        throw VideoCompositorError.shaderCompilationFailed("The default Metal library was not found.")
    }

    private static func shaderBundle(bundleToken: AnyClass) -> Bundle? {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: bundleToken)
        #endif
    }

    private static func makeLibraryFromSource(
        device: MTLDevice,
        bundle: Bundle
    ) throws -> MTLLibrary? {
        let sourceURLs = [
            bundle.url(forResource: "InputDeviceShaders", withExtension: "metal"),
            bundle.url(forResource: "VideoCompositorShaders", withExtension: "metal")
        ].compactMap { $0 }

        guard sourceURLs.count == 2 else {
            return nil
        }

        let source = try sourceURLs
            .map { url in
                "// \(url.lastPathComponent)\n" + (try String(contentsOf: url, encoding: .utf8))
            }
            .joined(separator: "\n\n")
        return try device.makeLibrary(source: source, options: nil)
    }
}
