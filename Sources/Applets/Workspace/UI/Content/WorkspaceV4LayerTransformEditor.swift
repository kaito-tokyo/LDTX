// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletService
import LDTXYouTubeRTMPS
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceV4LayerTransformEditor: View {
  @Bindable var store: WorkspaceV4Store
  @Bindable var session: WorkspaceV4SessionService
  let programInternalID: UInt64
  let role: ProgramCanvasRole
  let videoLayerInternalID: UInt64

  var body: some View {
    DisclosureGroup("Transform") {
      VStack(alignment: .leading) {
        transformSlider("X", value: valueBinding(\.translationX, defaultValue: 0), range: 0...1)
        transformSlider("Y", value: valueBinding(\.translationY, defaultValue: 0), range: 0...1)
        transformSlider("Scale X", value: valueBinding(\.scaleX, defaultValue: 1), range: 0.01...2)
        transformSlider("Scale Y", value: valueBinding(\.scaleY, defaultValue: 1), range: 0.01...2)
      }
      .padding(.leading)
    }
  }

  private func transformSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    HStack {
      Text(title).frame(width: 56, alignment: .leading)
      Slider(value: value, in: range)
    }
  }

  private func valueBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_BasicTransform, Float>,
    defaultValue: Float
  ) -> Binding<Double> {
    Binding(
      get: {
        let value = transform[keyPath: keyPath]
        return Double(value == 0 && defaultValue != 0 ? defaultValue : value)
      },
      set: { value in
        var transform = transform
        transform[keyPath: keyPath] = Float(value)
        try? session.setBasicTransform(
          transform, forVideoLayerInternalID: videoLayerInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
      }
    )
  }

  private var transform: Ldtx_Workspace_V4_BasicTransform {
    let preference = store.preferences.programPreferences[
      programInternalID]
    let transforms =
      role == .landscape
      ? preference?.landscapeVideoLayerTransforms : preference?.portraitVideoLayerTransforms
    return transforms?[videoLayerInternalID] ?? .init()
  }
}
