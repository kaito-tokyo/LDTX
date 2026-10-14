// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VideoComponentWrapper {
  public var internalID: Int64? {
    switch videoComponent {
    case .solidColorFill(let component): component.hasInternalID ? component.internalID : nil
    case .linearGradientFill(let component): component.hasInternalID ? component.internalID : nil
    case .radialGradientFill(let component): component.hasInternalID ? component.internalID : nil
    case .conicGradientFill(let component): component.hasInternalID ? component.internalID : nil
    case .vfxSource(let component): component.hasInternalID ? component.internalID : nil
    case .clock(let component): component.hasInternalID ? component.internalID : nil
    case .testPattern(let component): component.hasInternalID ? component.internalID : nil
    case nil: nil
    }
  }

  public var displayName: String? {
    switch videoComponent {
    case .solidColorFill(let component): component.hasDisplayName ? component.displayName : nil
    case .linearGradientFill(let component): component.hasDisplayName ? component.displayName : nil
    case .radialGradientFill(let component): component.hasDisplayName ? component.displayName : nil
    case .conicGradientFill(let component): component.hasDisplayName ? component.displayName : nil
    case .vfxSource(let component): component.hasDisplayName ? component.displayName : nil
    case .clock(let component): component.hasDisplayName ? component.displayName : nil
    case .testPattern(let component): component.hasDisplayName ? component.displayName : nil
    case nil: nil
    }
  }

  public var canBeVisionInput: Bool {
    switch videoComponent {
    case .vfxSource: true
    case .solidColorFill, .linearGradientFill, .radialGradientFill, .conicGradientFill,
      .clock, .testPattern, nil:
      false
    }
  }

  public var renderingSize: (width: UInt32, height: UInt32)? {
    switch videoComponent {
    case .vfxSource(let component): (component.deviceWidth, component.deviceHeight)
    case .solidColorFill, .linearGradientFill, .radialGradientFill, .conicGradientFill,
      .clock, .testPattern, nil:
      nil
    }
  }
}
