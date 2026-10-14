// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_VisionRegionOfInterest {
  /// Resolves absent numerators and denominators using the input's pixel dimensions.
  /// Explicit values, including zero denominators, are preserved for validation.
  public func resolved(inputSize: (width: UInt32, height: UInt32)) throws -> Self {
    func fraction<Value: Rational32Value>(
      _ value: Value, numerator: UInt32, denominator: UInt32
    ) throws -> Value {
      var result = value
      guard let num = value.hasNum ? value.num : Int32(exactly: numerator) else {
        throw Rational32EncodingError.unrepresentableDecimal
      }
      result.set(num: num, den: value.hasDen ? value.den : denominator)
      return result
    }
    var result = self
    result.x = try fraction(x, numerator: 0, denominator: inputSize.width)
    result.y = try fraction(y, numerator: 0, denominator: inputSize.height)
    result.width = try fraction(width, numerator: inputSize.width, denominator: inputSize.width)
    result.height = try fraction(height, numerator: inputSize.height, denominator: inputSize.height)
    return result
  }
}

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
