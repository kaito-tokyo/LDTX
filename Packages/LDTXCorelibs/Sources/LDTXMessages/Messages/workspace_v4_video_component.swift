// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VideoComponentWrapper {
  public var internalID: Int64? {
    switch videoComponent {
    case .solidColorFill(let component): component.internalID
    case .linearGradientFill(let component): component.internalID
    case .radialGradientFill(let component): component.internalID
    case .conicGradientFill(let component): component.internalID
    case .vfxSource(let component): component.internalID
    case .clock(let component): component.internalID
    case .dynamicText(let component): component.internalID
    case .testPattern(let component): component.internalID
    case nil: nil
    }
  }

  public var displayName: String? {
    switch videoComponent {
    case .solidColorFill(let component): component.displayName
    case .linearGradientFill(let component): component.displayName
    case .radialGradientFill(let component): component.displayName
    case .conicGradientFill(let component): component.displayName
    case .vfxSource(let component): component.displayName
    case .clock(let component): component.displayName
    case .dynamicText(let component): component.displayName
    case .testPattern(let component): component.displayName
    case nil: nil
    }
  }

  public var canBeVisionInput: Bool {
    switch videoComponent {
    case .vfxSource: true
    case .solidColorFill, .linearGradientFill, .radialGradientFill, .conicGradientFill,
      .clock, .dynamicText, .testPattern, nil:
      false
    }
  }

  public var renderingSize: (width: UInt32, height: UInt32)? {
    switch videoComponent {
    case .vfxSource(let component):
      if let width = component.deviceWidth, let height = component.deviceHeight {
        (width, height)
      } else {
        nil
      }
    case .solidColorFill, .linearGradientFill, .radialGradientFill, .conicGradientFill,
      .clock, .dynamicText, .testPattern, nil:
      nil
    }
  }
}
