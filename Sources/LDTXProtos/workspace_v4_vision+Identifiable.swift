// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VisionWrapper: Identifiable {
  public enum ID: Hashable {
    case ocrVision(UInt64)
    case invalid
  }

  public var id: ID {
    switch definition {
    case .ocrVision(let vision): .ocrVision(vision.internalID)
    case nil: .invalid
    }
  }
}
