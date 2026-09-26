// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum WorkspaceInspectorKind: Hashable {
  case programVideoLayers
  case workspaceCanvas
  case workspaceOutput
  case audioInputDevice(UInt64)
  case videoInputDevice(UInt64)
  case vfxVideoComponent(UInt64)
  case solidColorFillVideoComponent(UInt64)
  case linearGradientFillVideoComponent(UInt64)
  case radialGradientFillVideoComponent(UInt64)
  case conicGradientFillVideoComponent(UInt64)
  case clockVideoComponent(UInt64)
  case testPatternVideoComponent(UInt64)
  case ocrVision(UInt64)
}
