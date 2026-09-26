// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct ProgramVideoLayersInspector: View {
  let uiState: WorkspaceUIState
  let store: any WorkspaceBundleStoreProtocol
  let session: (any WorkspaceSessionProtocol)?
  let recordingSession: (any WorkspaceRecordingSessionProtocol)?

  var body: some View {
    if let program = selectedProgram {
      Section("Video Layers — \(program.displayName)") {
        layerList(role: .landscape, internalIDs: program.landscapeVideoLayerInternalIds)
        addLayerMenu(role: .landscape, internalIDs: program.landscapeVideoLayerInternalIds)
      }
      Section("Portrait Layers") {
        layerList(role: .portrait, internalIDs: program.portraitVideoLayerInternalIds)
        addLayerMenu(role: .portrait, internalIDs: program.portraitVideoLayerInternalIds)
      }
    } else {
      Section("Video Layers") {
        Text("No Program selected").foregroundStyle(.secondary)
      }
    }
  }

  private var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    guard let selectedID = store.selectedProgramInternalID else { return nil }
    return uiState.definition.programs.first { $0.internalID == selectedID }
  }

  @ViewBuilder
  private func layerList(role: ProgramCanvasRole, internalIDs: [UInt64]) -> some View {
    ForEach(Array(internalIDs.enumerated()), id: \.element) { index, internalID in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(layerName(for: internalID))
            .lineLimit(1)
          Spacer()
          Button {
            moveLayer(role: role, from: index, by: -1)
          } label: {
            Image(systemName: "arrow.up")
          }
          .disabled(index == 0 || session == nil || isRecording)
          Button {
            moveLayer(role: role, from: index, by: 1)
          } label: {
            Image(systemName: "arrow.down")
          }
          .disabled(index == internalIDs.count - 1 || session == nil || isRecording)
          Button(role: .destructive) {
            removeLayer(role: role, internalID: internalID)
          } label: {
            Image(systemName: "minus")
          }
          .disabled(session == nil || isRecording)
        }
        if let session, let selectedProgram {
          WorkspaceV4LayerTransformEditor(
            store: store, session: session, programInternalID: selectedProgram.internalID,
            role: role, videoLayerInternalID: internalID
          )
          .disabled(isRecording)
        }
      }
    }
  }

  @ViewBuilder
  private func addLayerMenu(role: ProgramCanvasRole, internalIDs: [UInt64]) -> some View {
    let existing = Set(internalIDs)
    Menu("Add Video Layer") {
      let devices = uiState.definition.inputDevices.compactMap { wrapper -> LayerItem? in
        guard case .videoDevice(let device) = wrapper.definition,
          !existing.contains(device.internalID)
        else { return nil }
        return LayerItem(id: device.internalID, name: device.displayName)
      }
      if !devices.isEmpty {
        Section("Video Input Devices") {
          ForEach(devices) { item in
            Button(item.name) { appendLayer(role: role, internalID: item.id) }
          }
        }
      }
      let components = uiState.definition.videoComponents.compactMap { wrapper -> LayerItem? in
        guard let id = wrapper.internalID, !existing.contains(id) else { return nil }
        return LayerItem(id: id, name: wrapper.displayName)
      }
      if !components.isEmpty {
        Section("Video Components") {
          ForEach(components) { item in
            Button(item.name) { appendLayer(role: role, internalID: item.id) }
          }
        }
      }
    }
    .disabled(session == nil || isRecording)
  }

  private func layerName(for internalID: UInt64) -> String {
    if let device = uiState.definition.inputDevices.compactMap({
      wrapper -> Ldtx_Workspace_V4_VideoInputDevice? in
      guard case .videoDevice(let device) = wrapper.definition,
        device.internalID == internalID
      else { return nil }
      return device
    }).first {
      return device.displayName
    }
    return uiState.definition.videoComponents.first { $0.internalID == internalID }?.displayName
      ?? "Missing Video Layer"
  }

  private func moveLayer(role: ProgramCanvasRole, from index: Int, by offset: Int) {
    guard let program = selectedProgram, let session else { return }
    var ids =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    let destination = index + offset
    guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
    ids.swapAt(index, destination)
    try? session.setVideoLayerOrder(ids, forProgramInternalID: program.internalID, role: role)
    uiState.definition = session.definition
  }

  private func removeLayer(role: ProgramCanvasRole, internalID: UInt64) {
    guard let program = selectedProgram, let session else { return }
    var ids =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    ids.removeAll { $0 == internalID }
    try? session.setVideoLayerOrder(ids, forProgramInternalID: program.internalID, role: role)
    uiState.definition = session.definition
  }

  private func appendLayer(role: ProgramCanvasRole, internalID: UInt64) {
    guard let program = selectedProgram, let session else { return }
    var ids =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    guard !ids.contains(internalID) else { return }
    ids.append(internalID)
    try? session.setVideoLayerOrder(ids, forProgramInternalID: program.internalID, role: role)
    uiState.definition = session.definition
  }

  private var isRecording: Bool { recordingSession?.isRecording ?? false }

  private struct LayerItem: Identifiable {
    let id: UInt64
    let name: String
  }
}

extension Ldtx_Workspace_V4_VideoComponentWrapper {
  fileprivate var internalID: UInt64? {
    switch definition {
    case .solidColorFill(let value): value.internalID
    case .linearGradientFill(let value): value.internalID
    case .radialGradientFill(let value): value.internalID
    case .conicGradientFill(let value): value.internalID
    case .vfxSource(let value): value.internalID
    case .clock(let value): value.internalID
    case .testPattern(let value): value.internalID
    case nil: nil
    }
  }

  fileprivate var displayName: String {
    switch definition {
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .vfxSource(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Video Component"
    }
  }
}
