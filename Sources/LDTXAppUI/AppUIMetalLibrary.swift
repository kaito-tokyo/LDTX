// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Metal

enum AppUIMetalLibrary {
    static func makeLibrary(device: any MTLDevice) -> MTLLibrary? {
        if let library = try? device.makeDefaultLibrary(bundle: .module) {
            return library
        }
        return device.makeDefaultLibrary()
    }
}
