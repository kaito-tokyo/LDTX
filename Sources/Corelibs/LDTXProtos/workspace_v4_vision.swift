// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VisionWrapper {
  public var displayName: String? {
    switch vision {
    case .ocrVision(let value): value.hasDisplayName ? value.displayName : nil
    case .createMlImageClassificationVision(let value):
      value.hasDisplayName ? value.displayName : nil
    case nil: nil
    }
  }
  public var internalID: UInt64? {
    switch vision {
    case .ocrVision(let value): value.hasInternalID ? value.internalID : nil
    case .createMlImageClassificationVision(let value): value.hasInternalID ? value.internalID : nil
    case nil: nil
    }
  }
}

extension Ldtx_Workspace_V4_VisionWrapper: Identifiable {
  public enum ID: Hashable {
    case ocrVision(UInt64)
    case createMlImageClassificationVision(UInt64)
    case invalid
  }

  public var id: ID {
    guard internalID != nil else { return .invalid }
    return switch vision {
    case .ocrVision(let vision): .ocrVision(vision.internalID)
    case .createMlImageClassificationVision(let vision):
      .createMlImageClassificationVision(vision.internalID)
    case nil: .invalid
    }
  }
}

extension Ldtx_Workspace_V4_OcrVision {
  public var videoComponentInternalIDIfPresent: UInt64? {
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

extension Ldtx_Workspace_V4_CreateMLImageClassificationVision {
  public var videoComponentInternalIDIfPresent: UInt64? {
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
