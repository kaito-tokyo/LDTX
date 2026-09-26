// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum WorkspaceInspectorKind: Hashable {
  case videoLayers
  case canvas
  case output
  case inputDevice(UInt64)
  case videoComponent(UInt64)
  case vision(UInt64)
}
