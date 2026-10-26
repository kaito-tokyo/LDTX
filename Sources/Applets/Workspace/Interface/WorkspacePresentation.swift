// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXCorelibs
import MetalKit

@MainActor
public protocol WorkspaceDeviceRegistry: AnyObject {
  var cameras: [CameraCaptureSource] { get }
  var audioInputDevices: [AudioInputDevice] { get }
  var error: (any Error)? { get }
  var errorMessage: String? { get }
  var hasRefreshed: Bool { get }
  func refresh(reportErrors: Bool)
}

extension WorkspaceDeviceRegistry {
  public func refresh() { refresh(reportErrors: true) }
}

public protocol ProgramAudioPeakMeterPresenting: AnyObject, Sendable {
  func peak(for master: WorkspaceAudioMaster) -> Float
  func peak(for channelKey: String) -> Float
}

public protocol PreviewAccessibilityImageReading: AnyObject, Sendable {
  var size: CGSize { get }
  func data(for parameters: NSDictionary) -> Data?
  func clear()
}

/// The MTKView keeps its original owner and delegate; UI only reads this contract.
public protocol ProgramPreviewAccessibilityImageSource: MTKViewDelegate {
  var previewAccessibilityImage: any PreviewAccessibilityImageReading { get }
}
