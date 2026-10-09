// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceInspectorKind: Int, Sendable {
  case invalid = 0
  case workspaceCanvas = 2
  case workspaceOutput = 3
  case audioInputDevice = 4
  case vfxVideoComponent = 6
  case solidColorFillVideoComponent = 7
  case linearGradientFillVideoComponent = 8
  case radialGradientFillVideoComponent = 9
  case conicGradientFillVideoComponent = 10
  case clockVideoComponent = 11
  case testPatternVideoComponent = 12
  case ocrVision = 13
  case workspacePrograms = 14
  case createMlImageClassifierVision = 15
}

public struct WorkspaceInspectorSelector: Hashable, Sendable {
  public let kind: WorkspaceInspectorKind
  public let internalID: UInt64?

  public init(kind: WorkspaceInspectorKind, internalID: UInt64? = nil) {
    self.kind = kind
    self.internalID = internalID
  }

  public func asRepresentation() -> WorkspaceInspectorSelectorRepresentation {
    WorkspaceInspectorSelectorRepresentation(kindID: kind.rawValue, internalID: internalID)
  }
}

public final class WorkspaceInspectorSelectorRepresentation: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool { true }

  public let kindID: Int
  public let internalID: UInt64?

  public init(kindID: Int, internalID: UInt64?) {
    self.kindID = kindID
    self.internalID = internalID
    super.init()
  }

  public var selector: WorkspaceInspectorSelector? {
    guard let kind = WorkspaceInspectorKind(rawValue: kindID) else { return nil }
    return WorkspaceInspectorSelector(kind: kind, internalID: internalID)
  }

  public required init?(coder: NSCoder) {
    guard coder.containsValue(forKey: "kindID") else { return nil }
    kindID = coder.decodeInteger(forKey: "kindID")
    internalID =
      coder.containsValue(forKey: "internalID")
      ? UInt64(bitPattern: coder.decodeInt64(forKey: "internalID"))
      : nil
    super.init()
  }

  public func encode(with coder: NSCoder) {
    coder.encode(kindID, forKey: "kindID")
    if let internalID {
      coder.encode(Int64(bitPattern: internalID), forKey: "internalID")
    }
  }
}
