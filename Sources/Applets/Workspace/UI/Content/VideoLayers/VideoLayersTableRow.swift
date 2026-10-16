// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Observation
import SwiftUI

@MainActor @Observable final class VideoLayersTableRowState {
  @ObservationIgnored var onCommit: () -> Void = {}
  @ObservationIgnored var onSetHidden: (Bool) -> Void = { _ in }
  var name = ""
  var isHidden = false
  var supportsPlacement = true
  var strings = ["0", "0", "1", "1"]
  var transform = Ldtx_Workspace_V4_BasicTransform()
  @ObservationIgnored private var displayedStrings = ["0", "0", "1", "1"]
  var hasLocalTextChanges = false

  func edit(_ text: String, at index: Int) {
    strings[index] = text
    hasLocalTextChanges = strings != displayedStrings
    onCommit()
  }
  var isEditing = false

  func display(
    _ transform: Ldtx_Workspace_V4_BasicTransform, canvasWidth: Double, canvasHeight: Double
  ) {
    self.transform = transform
    strings = [
      pixelPosition(transform.translationX, size: canvasWidth),
      pixelPosition(transform.translationY, size: canvasHeight),
      RationalValueFormatStyle<Ldtx_Workspace_V4_Rational32DefaultOne>().format(transform.scaleX),
      RationalValueFormatStyle<Ldtx_Workspace_V4_Rational32DefaultOne>().format(transform.scaleY),
    ]
    displayedStrings = strings
    hasLocalTextChanges = false
  }

  private func pixelPosition(_ value: Ldtx_Workspace_V4_Rational32, size: Double) -> String {
    let pixels = (value.double * size).rounded()
    guard let integer = Int32(exactly: pixels) else { return "0" }
    return String(integer)
  }

}

struct VideoLayersTableRowContent: View {
  @Bindable var state: VideoLayersTableRowState
  let canvasWidth: Double
  let canvasHeight: Double
  var dragToken: String = ""
  @FocusState private var focusedField: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(state.name).lineLimit(1)
        Spacer()
      }
      .frame(height: 28)
      .contentShape(Rectangle())
      .draggable(dragToken)
      HStack {
        Toggle(
          "Hide", isOn: Binding(get: { state.isHidden }, set: { state.onSetHidden($0) })
        )
        .toggleStyle(.checkbox)
        .fixedSize()
        if state.supportsPlacement {
          Grid(alignment: .leading) {
            ForEach(0..<2) { row in
              GridRow {
                ForEach(0..<2) { column in
                  let index = row * 2 + column
                  Text(["Pos X", "Pos Y", "Scale X", "Scale Y"][index]).fixedSize()
                  TextField(
                    ["Pos X", "Pos Y", "Scale X", "Scale Y"][index],
                    text: Binding(
                      get: { state.strings[index] },
                      set: {
                        guard state.strings[index] != $0 else { return }
                        state.edit($0, at: index)
                      })
                  )
                  .focused($focusedField, equals: index)
                  .frame(minWidth: 60)
                }
              }
            }
          }
        }
      }
    }
    .textFieldStyle(.roundedBorder)
    .autocorrectionDisabled()
    .writingToolsBehavior(.disabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 2)
    .onChange(of: focusedField) { _, new in
      state.isEditing = new != nil
    }
  }
}
