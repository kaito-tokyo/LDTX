// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

struct VfxVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let deviceRegistry: DeviceRegistryService
  let appletData: WorkspaceAppletData

  var body: some View {
    Form {
      formContent
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    Section("VFX Source") {
      if let component {
        TextField("Name", text: nameBinding)
          .disabled(uiState.isOutputActive)
        WorkspacePhysicalDeviceField(
          title: "Physical Device", internalID: internalID, isAudio: false,
          uiState: uiState, appletData: appletData, deviceRegistry: deviceRegistry)
        Toggle("Background Removal", isOn: backgroundRemovalBinding)
          .disabled(uiState.isOutputActive)
        Picker("Model", selection: backgroundRemovalModelBinding) {
          Text("MediaPipe Landscape").tag(
            Ldtx_Workspace_V4_BackgroundRemovalVfxEffect.Model.mediapipeLandscape)
          Text("Unspecified").tag(Ldtx_Workspace_V4_BackgroundRemovalVfxEffect.Model.unspecified)
        }
        .disabled(uiState.isOutputActive || !hasBackgroundRemoval)
        Text("Effects: \(component.effects.count)")
          .foregroundStyle(.secondary)
      } else {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }

  }

  private var component: Ldtx_Workspace_V4_VfxSourceComponent? {
    uiState.definition.videoComponents.compactMap { wrapper in
      guard case .vfxSource(let component) = wrapper.definition,
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
          guard case .vfxSource(var value) = wrapper.definition else { return }
          value.displayName = name
          wrapper.definition = .vfxSource(value)
        }
      }
    )
  }

  private var hasBackgroundRemoval: Bool {
    component?.effects.contains(where: {
      if case .backgroundRemoval = $0.definition { true } else { false }
    }) ?? false
  }

  private var backgroundRemovalBinding: Binding<Bool> {
    Binding(
      get: { hasBackgroundRemoval },
      set: { enabled in
        updateVideoComponent { wrapper in
          guard case .vfxSource(var value) = wrapper.definition else { return }
          value.effects.removeAll {
            if case .backgroundRemoval = $0.definition { true } else { false }
          }
          if enabled {
            var effect = Ldtx_Workspace_V4_BackgroundRemovalVfxEffect()
            effect.model = .mediapipeLandscape
            var effectWrapper = Ldtx_Workspace_V4_VideoEffectWrapper()
            effectWrapper.definition = .backgroundRemoval(effect)
            value.effects.append(effectWrapper)
          }
          wrapper.definition = .vfxSource(value)
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
          guard case .backgroundRemoval(let value) = wrapper.definition else { return nil }
          return value.model
        }.first ?? .mediapipeLandscape
      },
      set: { model in
        updateVideoComponent { wrapper in
          guard case .vfxSource(var value) = wrapper.definition,
            let index = value.effects.firstIndex(where: {
              if case .backgroundRemoval = $0.definition { true } else { false }
            }),
            case .backgroundRemoval(var effect) = value.effects[index].definition
          else { return }
          effect.model = model
          value.effects[index].definition = .backgroundRemoval(effect)
          wrapper.definition = .vfxSource(value)
        }
      }
    )
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: { wrapper in
        switch wrapper.id {
        case .solidColorFill(let id), .linearGradientFill(let id), .radialGradientFill(let id),
          .conicGradientFill(let id), .vfxSource(let id), .clock(let id), .testPattern(let id):
          id == internalID
        case .invalid:
          false
        }
      })
    else { return }
    mutation(&definition.videoComponents[index])
    uiState.definition = definition
  }

}
