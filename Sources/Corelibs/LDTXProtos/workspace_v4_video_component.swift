// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VideoComponentWrapper {
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
}

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
}
