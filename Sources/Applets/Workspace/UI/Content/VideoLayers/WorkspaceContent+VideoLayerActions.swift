// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface

extension WorkspaceContent {
  func performVideoLayerAction(
    _ internalID: UInt64, action: VideoLayerAction, programInternalID: UInt64, isPortrait: Bool
  ) {
    guard !uiState.isOutputActive,
      let programIndex = uiState.definition.programs.firstIndex(where: {
        $0.internalID == programInternalID
      })
    else { return }

    switch action {
    case .mute, .unmute:
      var preferences = uiState.preferences
      var preference = preferences.programPreferences[programInternalID] ?? .init()
      if isPortrait {
        preference.portraitVideoLayerMuted[internalID] = action == .mute
      } else {
        preference.landscapeVideoLayerMuted[internalID] = action == .mute
      }
      preferences.programPreferences[programInternalID] = preference
      uiState.preferences = preferences
    case .add, .remove, .moveUp, .moveDown:
      var definition = uiState.definition
      let program = definition.programs[programIndex]
      var layerIDs =
        isPortrait
        ? program.portraitVideoLayerInternalIds : program.landscapeVideoLayerInternalIds
      switch action {
      case .add:
        guard !layerIDs.contains(internalID) else { return }
        layerIDs.append(internalID)
      case .remove:
        layerIDs.removeAll { $0 == internalID }
      case .moveUp, .moveDown:
        guard let index = layerIDs.firstIndex(of: internalID) else { return }
        let destination = index + (action == .moveUp ? -1 : 1)
        guard layerIDs.indices.contains(destination) else { return }
        layerIDs.swapAt(index, destination)
      case .mute, .unmute:
        break
      }
      if isPortrait {
        definition.programs[programIndex].portraitVideoLayerInternalIds = layerIDs
      } else {
        definition.programs[programIndex].landscapeVideoLayerInternalIds = layerIDs
      }
      uiState.definition = definition
      errorMessage = nil
    }
  }
}
