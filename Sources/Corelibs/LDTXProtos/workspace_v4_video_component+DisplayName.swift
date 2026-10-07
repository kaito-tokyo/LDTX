// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VideoComponentWrapper {
  public var displayName: String? {
    switch definition {
    case .vfxSource(let component): component.displayName
    case .solidColorFill(let component): component.displayName
    case .linearGradientFill(let component): component.displayName
    case .radialGradientFill(let component): component.displayName
    case .conicGradientFill(let component): component.displayName
    case .clock(let component): component.displayName
    case .testPattern(let component): component.displayName
    case nil: nil
    }
  }
}
