// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Observation

@MainActor
@Observable
public final class WorkspaceUIState {
  public typealias WorkspaceDefinition = Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public typealias VideoComponentWrapper = Ldtx_Workspace_V4_VideoComponentWrapper
  public typealias WorkspacePreferences = Ldtx_Workspace_V4_WorkspacePreferencesV4

  public var definition: WorkspaceDefinition {
    didSet {
      videoComponentsByID.removeAll(keepingCapacity: true)
      for component in definition.videoComponents {
        guard component.id != .invalid else { continue }
        videoComponentsByID[component.id] = component
      }
    }
  }

  public var preferences: WorkspacePreferences
  public var inspectorKind: WorkspaceInspectorKind?
  public var isOutputActive: Bool

  @ObservationIgnored private var videoComponentsByID:
    [VideoComponentWrapper.ID: VideoComponentWrapper] = [:]
  @ObservationIgnored private let definitionCommitter: (WorkspaceDefinition) throws -> Void

  public init(
    definition: WorkspaceDefinition,
    preferences: WorkspacePreferences,
    inspectorKind: WorkspaceInspectorKind?,
    isOutputActive: Bool = false,
    definitionCommitter: @escaping (Ldtx_Workspace_V4_WorkspaceDefinitionV4) throws -> Void = { _ in
    }
  ) {
    self.definition = definition
    self.preferences = preferences
    self.inspectorKind = inspectorKind
    self.isOutputActive = isOutputActive
    self.definitionCommitter = definitionCommitter
    self.videoComponentsByID = Dictionary()
    for component in definition.videoComponents {
      guard component.id != .invalid else { continue }
      self.videoComponentsByID[component.id] = component
    }
  }

  public func commitDefinition() throws {
    try definitionCommitter(definition)
  }

  @discardableResult
  func replaceVideoComponent(
    id: VideoComponentWrapper.ID,
    with videoComponentDefinition: VideoComponentWrapper.OneOf_Definition
  ) -> Bool {
    var updatedDefinition = definition
    guard let index = updatedDefinition.videoComponents.firstIndex(where: { $0.id == id }) else {
      return false
    }

    var wrapper = updatedDefinition.videoComponents[index]
    wrapper.definition = videoComponentDefinition
    guard wrapper.id == id else { return false }

    updatedDefinition.videoComponents[index] = wrapper
    definition = updatedDefinition
    return true
  }

  func findVideoComponent<VideoComponentProto>(id: VideoComponentWrapper.ID) -> VideoComponentProto? {
    return switch videoComponentsByID[id]?.definition {
    case .solidColorFill(let component): component as? VideoComponentProto
    case .linearGradientFill(let component): component as? VideoComponentProto
    case .radialGradientFill(let component): component as? VideoComponentProto
    case .conicGradientFill(let component): component as? VideoComponentProto
    case .vfxSource(let component): component as? VideoComponentProto
    case .clock(let component): component as? VideoComponentProto
    case .testPattern(let component): component as? VideoComponentProto
    case nil: nil
    }
  }
}
