// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture

public protocol CaptureDeviceService {
  func availableCameras() -> [CameraCaptureSource]
  func availableAudioDevices() -> [AudioCaptureSource]
}

public struct DefaultCaptureDeviceService: CaptureDeviceService {
  public init() {}

  public func availableCameras() -> [CameraCaptureSource] {
    LDTXCapture.CaptureSessionManager().availableCameras()
  }

  public func availableAudioDevices() -> [AudioCaptureSource] {
    LDTXCapture.CaptureSessionManager().availableAudioDevices()
  }
}
