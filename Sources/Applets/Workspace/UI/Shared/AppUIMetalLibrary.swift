// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import Foundation
import Metal

private final class AppletBundleToken {}

enum AppUIMetalLibrary {
  static func makeLibrary(device: any MTLDevice) -> MTLLibrary? {
    try? device.makeDefaultLibrary(bundle: Bundle(for: AppletBundleToken.self))
  }
}
