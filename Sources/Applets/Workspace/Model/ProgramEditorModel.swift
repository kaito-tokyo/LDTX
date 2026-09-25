// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

public enum ProgramOutputProfileID: String, Codable, CaseIterable, Sendable {
  case sdrLandscape1080p60 = "sdr-landscape-1080p60"
  case sdrPortrait1080p60 = "sdr-portrait-1080p60"

  /// Source compatibility for code that still names the original landscape preset.
  public static let sdr1080p60 = Self.sdrLandscape1080p60
}

public struct ProgramOutputConfiguration: Codable, Equatable, Sendable {
  public static let sdr1080p60VideoBitRate = 6_000_000
  /// The Canvas preset that selects the output encoding contract.
  public var profileID: ProgramOutputProfileID?
  public var canvasWidth: Int
  public var canvasHeight: Int
  public var frameRate: Int
  public var videoBitRate: Int
  public var portraitVideoBitRate: Int
  /// The Workspace Video Input Device that supplies output PTS. `nil` uses the host clock.
  public var videoPTSMasterInputDeviceID: String?

  public init(
    profileID: ProgramOutputProfileID? = .sdrLandscape1080p60,
    canvasWidth: Int = 1_920,
    canvasHeight: Int = 1_080,
    frameRate: Int = 60,
    videoBitRate: Int = 6_000_000,
    portraitVideoBitRate: Int = 6_000_000,
    videoPTSMasterInputDeviceID: String? = nil
  ) {
    self.profileID = profileID
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.frameRate = frameRate
    self.videoBitRate = videoBitRate
    self.portraitVideoBitRate = portraitVideoBitRate
    self.videoPTSMasterInputDeviceID = videoPTSMasterInputDeviceID
  }

  public var isSupportedOutputProfile: Bool {
    profileID == .sdrLandscape1080p60
      && canvasWidth == 1_920
      && canvasHeight == 1_080
      && frameRate == 60
      && videoBitRate > 0
      && portraitVideoBitRate > 0
  }

  private enum CodingKeys: String, CodingKey {
    case profileID, canvasWidth, canvasHeight, frameRate, videoBitRate, portraitVideoBitRate,
      videoPTSMasterInputDeviceID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canvasWidth = try container.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? 1_920
    canvasHeight = try container.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? 1_080
    frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 60
    videoBitRate = try container.decodeIfPresent(Int.self, forKey: .videoBitRate) ?? 6_000_000
    portraitVideoBitRate =
      try container.decodeIfPresent(Int.self, forKey: .portraitVideoBitRate) ?? 6_000_000
    videoPTSMasterInputDeviceID = try container.decodeIfPresent(
      String.self, forKey: .videoPTSMasterInputDeviceID
    )
    profileID = try container.decodeIfPresent(ProgramOutputProfileID.self, forKey: .profileID)
  }

  public func normalizedForOutputPreset() -> ProgramOutputConfiguration? {
    guard isSupportedOutputProfile else { return nil }
    return self
  }

  public static let sdr1080p60 = ProgramOutputConfiguration(
    profileID: .sdr1080p60,
    canvasWidth: 1_920,
    canvasHeight: 1_080,
    frameRate: 60, videoBitRate: sdr1080p60VideoBitRate
  )
}

public struct ProgramVideoComponentRecord: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var component: ProgramComponent

  public var id: String { name }

  public init(
    name: String,
    inputDeviceID: String? = nil,
    sourceCropTop: Float = 0,
    sourceCropRight: Float = 0,
    sourceCropBottom: Float = 0,
    sourceCropLeft: Float = 0,
    removesBackground: Bool = false
  ) {
    self.name = name
    self.component = .inputCameraDevice(
      InputDeviceComponent(
        inputDeviceID: inputDeviceID,
        sourceCropTop: sourceCropTop,
        sourceCropRight: sourceCropRight,
        sourceCropBottom: sourceCropBottom,
        sourceCropLeft: sourceCropLeft,
        removesBackground: removesBackground
      ))
  }

  public init(name: String, component: ProgramComponent) {
    self.name = name
    self.component = component
  }

  public var inputDeviceID: String? {
    get { inputDeviceComponent?.inputDeviceID }
    set { updateInputDeviceComponent { $0.inputDeviceID = newValue } }
  }
  public var sourceCropTop: Float {
    get { inputDeviceComponent?.sourceCropTop ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropTop = newValue } }
  }
  public var sourceCropRight: Float {
    get { inputDeviceComponent?.sourceCropRight ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropRight = newValue } }
  }
  public var sourceCropBottom: Float {
    get { inputDeviceComponent?.sourceCropBottom ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropBottom = newValue } }
  }
  public var sourceCropLeft: Float {
    get { inputDeviceComponent?.sourceCropLeft ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropLeft = newValue } }
  }
  public var removesBackground: Bool {
    get { inputDeviceComponent?.removesBackground ?? false }
    set { updateInputDeviceComponent { $0.removesBackground = newValue } }
  }

  private var inputDeviceComponent: InputDeviceComponent? {
    guard case .inputCameraDevice(let payload) = component else { return nil }
    return payload
  }

  private mutating func updateInputDeviceComponent(_ update: (inout InputDeviceComponent) -> Void) {
    guard case .inputCameraDevice(var payload) = component else { return }
    update(&payload)
    component = .inputCameraDevice(payload)
  }
}
