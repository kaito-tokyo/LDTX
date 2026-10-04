// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

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
    case .hide, .show:
      var preferences = uiState.preferences
      var preference =
        (isPortrait
        ? preferences.portraitProgramPreferences : preferences.landscapeProgramPreferences)[
          programInternalID] ?? .init()
      preference.videoLayerHidden[internalID] = action == .hide
      if isPortrait {
        preferences.portraitProgramPreferences[programInternalID] = preference
      } else {
        preferences.landscapeProgramPreferences[programInternalID] = preference
      }
      uiState.preferences = preferences
    case .add, .remove, .moveUp, .moveDown, .move:
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
      case .move(let offsets, let destination):
        guard !offsets.isEmpty, offsets.allSatisfy({ layerIDs.indices.contains($0) }),
          (0...layerIDs.count).contains(destination)
        else { return }
        layerIDs.move(fromOffsets: offsets, toOffset: destination)
      case .hide, .show:
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
