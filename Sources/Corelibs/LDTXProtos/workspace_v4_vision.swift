// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VisionWrapper {
  public var displayName: String? {
    switch vision {
    case .ocrVision(let value): value.hasDisplayName ? value.displayName : nil
    case .ldtxSceneDetectorVision(let value):
      value.hasDisplayName ? value.displayName : nil
    case nil: nil
    }
  }
  public var internalID: Int64? {
    switch vision {
    case .ocrVision(let value): value.hasInternalID ? value.internalID : nil
    case .ldtxSceneDetectorVision(let value): value.hasInternalID ? value.internalID : nil
    case nil: nil
    }
  }
}

extension Ldtx_Workspace_V4_OcrVision {
  public var videoComponentInternalIDIfPresent: Int64? {
    get {
      guard hasVideoComponentInternalID, videoComponentInternalID != 0 else { return nil }
      return videoComponentInternalID
    }
    set {
      if let newValue, newValue != 0 {
        videoComponentInternalID = newValue
      } else {
        clearVideoComponentInternalID()
      }
    }
  }
}

extension Ldtx_Workspace_V4_LdtxSceneDetectorVision {
  public var videoComponentInternalIDIfPresent: Int64? {
    get {
      guard hasVideoComponentInternalID, videoComponentInternalID != 0 else { return nil }
      return videoComponentInternalID
    }
    set {
      if let newValue, newValue != 0 {
        videoComponentInternalID = newValue
      } else {
        clearVideoComponentInternalID()
      }
    }
  }
}
