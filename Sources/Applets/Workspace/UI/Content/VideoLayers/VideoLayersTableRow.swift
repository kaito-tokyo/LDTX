// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import Observation
import SwiftUI

@MainActor @Observable final class VideoLayersTableRowState {
  @ObservationIgnored var onCommit: (UndoManager?) -> Void = { _ in }
  @ObservationIgnored var onSetHidden: (Bool, UndoManager?) -> Void = { _, _ in }
  var name = ""
  var isHidden = false
  var supportsPlacement = true
  var strings = ["0", "0", "1", "1"]
  var transform = Ldtx_Workspace_V4_BasicTransform()
  @ObservationIgnored private var displayedStrings = ["0", "0", "1", "1"]
  var hasLocalTextChanges = false

  func edit(_ text: String, at index: Int, undoManager: UndoManager? = nil) {
    strings[index] = text
    hasLocalTextChanges = strings != displayedStrings
    onCommit(undoManager)
  }
  var isEditing = false

  func display(
    _ transform: Ldtx_Workspace_V4_BasicTransform, canvasWidth: Double, canvasHeight: Double
  ) {
    self.transform = transform
    strings = [
      pixelPosition(transform.translationX, size: canvasWidth),
      pixelPosition(transform.translationY, size: canvasHeight),
      RationalValueFormatStyle<Ldtx_Workspace_V4_Rational32DefaultOne>().format(
        transform.scaleX ?? .init()),
      RationalValueFormatStyle<Ldtx_Workspace_V4_Rational32DefaultOne>().format(
        transform.scaleY ?? .init()),
    ]
    displayedStrings = strings
    hasLocalTextChanges = false
  }

  private func pixelPosition(_ value: Ldtx_Workspace_V4_Rational32?, size: Double) -> String {
    let pixels = ((value?.double ?? 0) * size).rounded()
    guard let integer = Int32(exactly: pixels) else { return "0" }
    return String(integer)
  }

}

struct VideoLayersTableRowContent: View {
  @Environment(\.undoManager) private var undoManager
  @Bindable var state: VideoLayersTableRowState
  let canvasWidth: Double
  let canvasHeight: Double
  @State private var isHoveringHandle = false
  @FocusState private var focusedField: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
          .onHover { isHoveringHandle = $0 }
          .help("Drag to reorder")
          .accessibilityLabel("Reorder layer")
        Text(state.name).lineLimit(1)
        Spacer()
      }
      .frame(height: 28)
      HStack {
        Toggle(
          "Hide",
          isOn: Binding(get: { state.isHidden }, set: { state.onSetHidden($0, undoManager) })
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
                        state.edit($0, at: index, undoManager: undoManager)
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
    .moveDisabled(!isHoveringHandle)
    .onChange(of: focusedField) { _, new in
      state.isEditing = new != nil
    }
    .onDisappear {
      state.isEditing = false
      isHoveringHandle = false
    }
  }
}
