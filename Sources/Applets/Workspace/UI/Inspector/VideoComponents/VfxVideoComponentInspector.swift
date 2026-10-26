// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceAppletInterface
import SwiftUI

struct VfxVideoComponentInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let internalID: Int64
  let deviceRegistry: any WorkspaceDeviceRegistry
  let appletData: WorkspaceAppletData

  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: internalID)
      formContent
      VideoComponentDeleteButton(stateService: stateService, componentID: internalID)
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    Section("VFX Source") {
      if let component {
        TextField("Name", text: nameBinding)
          .disabled(stateService.isOutputActive)
        WorkspacePhysicalDeviceField(
          title: "Physical Device", internalID: internalID, isAudio: false,
          stateService: stateService, appletData: appletData, deviceRegistry: deviceRegistry,
          runtimeActions: runtimeActions)
        Toggle("Background Removal", isOn: backgroundRemovalBinding)
          .disabled(stateService.isOutputActive)
        Picker("Model", selection: backgroundRemovalModelBinding) {
          Text("MediaPipe Landscape").tag(
            Ldtx_Workspace_V4_BackgroundRemovalVfxEffect.Model.mediapipeLandscape)
          Text("Unspecified").tag(Ldtx_Workspace_V4_BackgroundRemovalVfxEffect.Model.unspecified)
        }
        .disabled(stateService.isOutputActive || !hasBackgroundRemoval)
        Text("Effects: \(component.effects.count)")
          .foregroundStyle(.secondary)
      } else {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }

  }

  private var component: Ldtx_Workspace_V4_VfxSourceComponent? {
    stateService.workspaceDefinition.videoComponents.compactMap { wrapper in
      guard case .vfxSource(let component) = wrapper.videoComponent,
        component.internalID == internalID
      else { return nil }
      return component
    }.first
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { component?.displayName ?? "" },
      set: { name in
        updateVideoComponent { wrapper in
          guard case .vfxSource(var value) = wrapper.videoComponent else { return }
          value.displayName = name
          wrapper.videoComponent = .vfxSource(value)
        }
      }
    )
  }

  private var hasBackgroundRemoval: Bool {
    component?.effects.contains(where: {
      if case .backgroundRemoval = $0.videoEffect { true } else { false }
    }) ?? false
  }

  private var backgroundRemovalBinding: Binding<Bool> {
    Binding(
      get: { hasBackgroundRemoval },
      set: { enabled in
        updateVideoComponent { wrapper in
          guard case .vfxSource(var value) = wrapper.videoComponent else { return }
          value.effects.removeAll {
            if case .backgroundRemoval = $0.videoEffect { true } else { false }
          }
          if enabled {
            var effect = Ldtx_Workspace_V4_BackgroundRemovalVfxEffect()
            effect.model = .mediapipeLandscape
            var effectWrapper = Ldtx_Workspace_V4_VideoEffectWrapper()
            effectWrapper.videoEffect = .backgroundRemoval(effect)
            value.effects.append(effectWrapper)
          }
          wrapper.videoComponent = .vfxSource(value)
        }
      }
    )
  }

  private var backgroundRemovalModelBinding:
    Binding<Ldtx_Workspace_V4_BackgroundRemovalVfxEffect.Model>
  {
    Binding(
      get: {
        component?.effects.compactMap {
          wrapper -> Ldtx_Workspace_V4_BackgroundRemovalVfxEffect.Model? in
          guard case .backgroundRemoval(let value) = wrapper.videoEffect else { return nil }
          return value.model
        }.first ?? .mediapipeLandscape
      },
      set: { model in
        updateVideoComponent { wrapper in
          guard case .vfxSource(var value) = wrapper.videoComponent,
            let index = value.effects.firstIndex(where: {
              if case .backgroundRemoval = $0.videoEffect { true } else { false }
            }),
            case .backgroundRemoval(var effect) = value.effects[index].videoEffect
          else { return }
          effect.model = model
          value.effects[index].videoEffect = .backgroundRemoval(effect)
          wrapper.videoComponent = .vfxSource(value)
        }
      }
    )
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == internalID })
    else { return }
    mutation(&definition.videoComponents[index])
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
  }

}
