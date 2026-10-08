// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VisionWrapper {
  public var displayName: String? {
    switch vision {
    case .ocrVision(let value): value.hasDisplayName ? value.displayName : nil
    case nil: nil
    }
  }
  public var internalID: UInt64? {
    switch vision {
    case .ocrVision(let value): value.hasInternalID ? value.internalID : nil
    case nil: nil
    }
  }
}
