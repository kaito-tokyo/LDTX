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
      guard !isApplyingValidatedWorkspace, !isRollingBackInvalidEdit else { return }
      guard
        (try? WorkspaceV4IntegrityValidator.validate(
          WorkspaceV4Bundle(definition: definition, preferences: preferences))) != nil
      else {
        isRollingBackInvalidEdit = true
        definition = oldValue
        isRollingBackInvalidEdit = false
        return
      }
      cacheVideoComponents(from: definition)
      workspaceDidChange?()
    }
  }

  public var preferences: WorkspacePreferences {
    didSet {
      guard !isApplyingValidatedWorkspace, !isRollingBackInvalidEdit else { return }
      guard
        (try? WorkspaceV4IntegrityValidator.validate(
          WorkspaceV4Bundle(definition: definition, preferences: preferences))) != nil
      else {
        isRollingBackInvalidEdit = true
        preferences = oldValue
        isRollingBackInvalidEdit = false
        return
      }
      workspaceDidChange?()
    }
  }

  public var inspectorKind: WorkspaceInspectorKind?
  public var isOutputActive: Bool
  @ObservationIgnored private var savedDefinition: WorkspaceDefinition
  @ObservationIgnored private var savedPreferences: WorkspacePreferences
  @ObservationIgnored public var workspaceDidChange: (() -> Void)?
  @ObservationIgnored private var isApplyingValidatedWorkspace = false
  @ObservationIgnored private var isRollingBackInvalidEdit = false

  @ObservationIgnored private var videoComponentsByID:
    [VideoComponentWrapper.ID: VideoComponentWrapper] = [:]

  public init(
    definition: WorkspaceDefinition = WorkspaceDefinition(),
    preferences: WorkspacePreferences = WorkspacePreferences(),
    inspectorKind: WorkspaceInspectorKind? = .programVideoLayers,
    isOutputActive: Bool = false
  ) {
    self.definition = definition
    self.preferences = preferences
    self.inspectorKind = inspectorKind
    self.isOutputActive = isOutputActive
    self.savedDefinition = definition
    self.savedPreferences = preferences
    self.videoComponentsByID = [:]
    cacheVideoComponents(from: definition)
  }

  public var workspace: WorkspaceV4Bundle {
    WorkspaceV4Bundle(definition: definition, preferences: preferences)
  }

  public var isDirty: Bool {
    definition != savedDefinition || preferences != savedPreferences
  }

  public func replaceDefinition(_ definition: WorkspaceDefinition) throws {
    try WorkspaceV4IntegrityValidator.validate(
      WorkspaceV4Bundle(definition: definition, preferences: preferences))
    self.definition = definition
  }

  public func replacePreferences(_ preferences: WorkspacePreferences) throws {
    try WorkspaceV4IntegrityValidator.validate(
      WorkspaceV4Bundle(definition: definition, preferences: preferences))
    self.preferences = preferences
  }

  public func replaceWorkspace(_ workspace: WorkspaceV4Bundle) throws {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    isApplyingValidatedWorkspace = true
    definition = workspace.definition
    preferences = workspace.preferences
    isApplyingValidatedWorkspace = false
    cacheVideoComponents(from: workspace.definition)
    workspaceDidChange?()
  }

  public func markSaved() {
    savedDefinition = definition
    savedPreferences = preferences
  }

  private func cacheVideoComponents(from definition: WorkspaceDefinition) {
    videoComponentsByID.removeAll(keepingCapacity: true)
    for component in definition.videoComponents {
      guard component.id != .invalid else { continue }
      videoComponentsByID[component.id] = component
    }
  }

  public static func cleanWorkspace(displayName: String) -> WorkspaceV4Bundle {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = displayName
    definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    definition.canvasConfiguration.frameRate = 60
    definition.canvasConfiguration.landscapeVideoBitRate = 6_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 6_000_000
    definition.outputConfiguration.youtubeIngestMode = .landscapeRtmps
    return WorkspaceV4Bundle(
      definition: definition,
      preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
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

  func findVideoComponent<VideoComponentProto>(id: VideoComponentWrapper.ID) -> VideoComponentProto?
  {
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
