// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

enum VideoLayerAction {
  case add
  case remove
  case moveUp
  case moveDown
  case mute
  case unmute
}

struct VideoLayersEditor: View {
  @Bindable var uiState: WorkspaceUIState
  let transforms: [UInt64: Ldtx_Workspace_V4_BasicTransform]
  let muted: [UInt64: Bool]
  let width: Double
  let height: Double
  let draftKeyPrefix: String
  let layerIDs: [UInt64]
  @Binding var transformDrafts: [String: [String]]
  let onAction: (UInt64, VideoLayerAction) -> Void

  var body: some View {
    VStack(alignment: .leading) {
      if layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
      ForEach(Array(layerIDs.enumerated()), id: \.element) { index, internalID in
        VStack(alignment: .leading) {
          HStack {
            Text(videoLayerDisplayName(for: internalID))
            Spacer()
            Toggle(
              "Mute",
              isOn: Binding(
                get: { muted[internalID] ?? false },
                set: { onAction(internalID, $0 ? .mute : .unmute) })
            )
            .toggleStyle(.checkbox)
            Button {
              onAction(internalID, .moveUp)
            } label: {
              Image(systemName: "arrow.up")
            }
            .disabled(uiState.isOutputActive || index == 0)
            Button {
              onAction(internalID, .moveDown)
            } label: {
              Image(systemName: "arrow.down")
            }
            .disabled(uiState.isOutputActive || index == layerIDs.count - 1)
            Button {
              onAction(internalID, .remove)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(videoLayerDisplayName(for: internalID))")
            .disabled(uiState.isOutputActive)
          }
          let transform = transforms[internalID] ?? .init()
          let key = "\(draftKeyPrefix)/\(internalID)"
          let initial = [
            String(Double(transform.translationX) * width),
            String(Double(transform.translationY) * height),
            String(transform.scaleX), String(transform.scaleY),
          ]
          VideoLayerTransformEditor(
            posXStr: Binding(
              get: { transformDrafts[key]?[0] ?? initial[0] },
              set: { transformDrafts[key, default: initial][0] = $0 }),
            posYStr: Binding(
              get: { transformDrafts[key]?[1] ?? initial[1] },
              set: { transformDrafts[key, default: initial][1] = $0 }),
            scaleXStr: Binding(
              get: { transformDrafts[key]?[2] ?? initial[2] },
              set: { transformDrafts[key, default: initial][2] = $0 }),
            scaleYStr: Binding(
              get: { transformDrafts[key]?[3] ?? initial[3] },
              set: { transformDrafts[key, default: initial][3] = $0 }))
        }
      }
      Menu("Add Video Layer") {
        ForEach(availableVideoLayerIDs, id: \.self) {
          internalID in
          Button(videoLayerDisplayName(for: internalID)) {
            onAction(internalID, .add)
          }
        }
      }
      .disabled(
        uiState.isOutputActive
          || availableVideoLayerIDs.isEmpty)
    }
  }

  private var availableVideoLayerIDs: [UInt64] {
    let usedIDs = Set(layerIDs)
    let inputIDs = uiState.definition.inputDevices.compactMap {
      input -> UInt64? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device.internalID
    }
    let componentIDs = uiState.definition.videoComponents.compactMap {
      componentInternalID($0)
    }
    return (inputIDs + componentIDs).filter { !usedIDs.contains($0) }
  }

  private func videoLayerDisplayName(for internalID: UInt64) -> String {
    if let input = uiState.definition.inputDevices.first(where: {
      input in
      switch input.definition {
      case .videoDevice(let device): device.internalID == internalID
      case .audioDevice, nil: false
      }
    }), case .videoDevice(let device)? = input.definition {
      return device.displayName
    }
    if let component = uiState.definition.videoComponents.first(where: {
      componentInternalID($0) == internalID
    }) {
      return componentDisplayName(component)
    }
    return "Missing Video Layer"
  }

  private func componentInternalID(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> UInt64?
  {
    switch component.definition {
    case .vfxSource(let value): value.internalID
    case .solidColorFill(let value): value.internalID
    case .linearGradientFill(let value): value.internalID
    case .radialGradientFill(let value): value.internalID
    case .conicGradientFill(let value): value.internalID
    case .clock(let value): value.internalID
    case .testPattern(let value): value.internalID
    case nil: nil
    }
  }

  private func componentDisplayName(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String
  {
    switch component.definition {
    case .vfxSource(let value): value.displayName
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Invalid Video Component"
    }
  }
}
