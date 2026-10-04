// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

enum VideoLayerAction: Equatable {
  case add
  case remove
  case moveUp
  case moveDown
  case move(fromOffsets: IndexSet, toOffset: Int)
  case hide
  case show
}

struct VideoLayersEditor: View {
  @Bindable var uiState: WorkspaceUIState
  let transforms: [UInt64: Ldtx_Workspace_V4_BasicTransform]
  let hidden: [UInt64: Bool]
  let width: Double
  let height: Double
  let layerIDs: [UInt64]
  let onAction: (UInt64, VideoLayerAction) -> Void
  let onCommitTransform: (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void

  var body: some View {
    VStack(alignment: .leading) {
      if layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
      VideoLayersTable(
        layerIDs: layerIDs, transforms: transforms, hidden: hidden,
        names: Dictionary(
          uniqueKeysWithValues: layerIDs.map { ($0, videoLayerDisplayName(for: $0)) }),
        width: width, height: height, isOutputActive: uiState.isOutputActive,
        onAction: onAction, onCommitTransform: onCommitTransform
      )
      .frame(
        height: CGFloat(layerIDs.count) * VideoLayersTableView.layerRowHeight
          + (layerIDs.isEmpty ? 0 : VideoLayersTableView.dropAreaHeight))
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
