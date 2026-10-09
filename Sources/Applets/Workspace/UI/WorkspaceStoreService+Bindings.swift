// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

extension Bindable where Value == WorkspaceStoreService {
  @MainActor
  func ocrVision(internalID: UInt64) -> Binding<Ldtx_Workspace_V4_OcrVision>? {
    let store = wrappedValue
    func currentVision() -> Ldtx_Workspace_V4_OcrVision? {
      store.definition.visions.compactMap { wrapper in
        guard case .ocrVision(let vision) = wrapper.vision,
          vision.internalID == internalID
        else { return nil }
        return vision
      }.first
    }
    guard let initial = currentVision() else { return nil }
    return Binding(
      // A removed item may still be read while SwiftUI tears down its Inspector.
      get: { currentVision() ?? initial },
      set: { updated in
        guard updated.internalID == internalID,
          let index = store.definition.visions.firstIndex(where: {
            guard case .ocrVision(let vision) = $0.vision else { return false }
            return vision.internalID == internalID
          })
        else { return }
        store.definition.visions[index].vision = .ocrVision(updated)
      })
  }
  @MainActor
  func createMlImageClassificationVision(internalID: UInt64) -> Binding<
    Ldtx_Workspace_V4_CreateMlImageClassificationVision
  >? {
    let store = wrappedValue
    func currentVision() -> Ldtx_Workspace_V4_CreateMlImageClassificationVision? {
      store.definition.visions.compactMap { wrapper in
        guard case .createMlImageClassificationVision(let vision) = wrapper.vision,
          vision.internalID == internalID
        else { return nil }
        return vision
      }.first
    }
    guard let initial = currentVision() else { return nil }
    return Binding(
      // A removed item may still be read while SwiftUI tears down its Inspector.
      get: { currentVision() ?? initial },
      set: { updated in
        guard updated.internalID == internalID,
          let index = store.definition.visions.firstIndex(where: {
            guard case .createMlImageClassificationVision(let vision) = $0.vision else {
              return false
            }
            return vision.internalID == internalID
          })
        else { return }
        store.definition.visions[index].vision = .createMlImageClassificationVision(updated)
      })
  }
}
