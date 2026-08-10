// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum AVCaptureDeviceConfigurationGate {
  private static let lock = NSLock()

  static func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer {
      lock.unlock()
    }
    return try body()
  }
}
