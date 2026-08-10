// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture

protocol CaptureDeviceService {
  func availableCameras() -> [CameraCaptureSource]
  func availableAudioDevices() -> [AudioCaptureSource]
}

struct DefaultCaptureDeviceService: CaptureDeviceService {
  func availableCameras() -> [CameraCaptureSource] {
    LDTXCapture.CaptureSessionManager().availableCameras()
  }

  func availableAudioDevices() -> [AudioCaptureSource] {
    LDTXCapture.CaptureSessionManager().availableAudioDevices()
  }
}
