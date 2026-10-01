// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_InputDeviceWrapper: Identifiable {
  public enum ID: Hashable {
    case videoDevice(UInt64)
    case audioDevice(UInt64)
    case invalid
  }

  public var id: ID {
    switch definition {
    case .videoDevice(let device): .videoDevice(device.internalID)
    case .audioDevice(let device): .audioDevice(device.internalID)
    case nil: .invalid
    }
  }
}
