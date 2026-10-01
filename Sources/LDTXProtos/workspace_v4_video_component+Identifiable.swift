// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VideoComponentWrapper: Identifiable {
  public enum ID: Hashable {
    case solidColorFill(UInt64)
    case linearGradientFill(UInt64)
    case radialGradientFill(UInt64)
    case conicGradientFill(UInt64)
    case vfxSource(UInt64)
    case clock(UInt64)
    case testPattern(UInt64)
    case invalid
  }

  public var id: ID {
    switch definition {
    case .solidColorFill(let component): .solidColorFill(component.internalID)
    case .linearGradientFill(let component): .linearGradientFill(component.internalID)
    case .radialGradientFill(let component): .radialGradientFill(component.internalID)
    case .conicGradientFill(let component): .conicGradientFill(component.internalID)
    case .vfxSource(let component): .vfxSource(component.internalID)
    case .clock(let component): .clock(component.internalID)
    case .testPattern(let component): .testPattern(component.internalID)
    case nil: .invalid
    }
  }
}
