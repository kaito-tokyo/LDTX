// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos

public enum LDTXVariableItem: String, CaseIterable, Hashable, Sendable {
  case text, label, confidence
  public var emptyValue: String { self == .confidence ? "0" : "" }
}

public struct LDTXVariableKey: Hashable, Sendable {
  public let id: String
  public let sel: String
  public init(id: String, sel: String) {
    self.id = id
    self.sel = sel
  }
  public init(visionID: Int64, item: LDTXVariableItem) {
    self.init(id: String(visionID), sel: item.rawValue)
  }
  public var path: String { "visions/\(id)/\(sel)" }
  public var visionID: Int64? { Int64(id) }
}

public enum WorkspaceVariableError: Error, Equatable { case unregisteredKey(LDTXVariableKey) }

extension Dictionary where Key == LDTXVariableKey, Value == String {
  public init(definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) {
    self.init()
    for wrapper in definition.visions {
      switch wrapper.vision {
      case .ocrVision(let vision):
        self[.init(visionID: vision.internalID, item: .text)] = ""
      case .ldtxSceneDetectorVision(let vision):
        self[.init(visionID: vision.internalID, item: .label)] = ""
        self[.init(visionID: vision.internalID, item: .confidence)] = "0"
      case nil: break
      }
    }
  }

  public mutating func update(_ values: [Key: Value]) throws {
    for key in values.keys where self[key] == nil {
      throw WorkspaceVariableError.unregisteredKey(key)
    }
    merge(values) { _, new in new }
  }

  public mutating func reset(visionID: Int64) {
    for key in keys where key.visionID == visionID {
      self[key] = key.sel == "confidence" ? "0" : ""
    }
  }
}
