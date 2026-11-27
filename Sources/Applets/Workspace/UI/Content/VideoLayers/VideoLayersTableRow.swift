// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import Observation
import SwiftUI

@MainActor @Observable final class VideoLayersTableRowState {
  @ObservationIgnored var onCommit: (UndoManager?) -> Void = { _ in }
  @ObservationIgnored var onSetHidden: (Bool, UndoManager?) -> Void = { _, _ in }
  /// Field indices in `strings`: position, scale, and then crop percentages.
  enum Field: Int, CaseIterable {
    case positionX, positionY, scaleX, scaleY, cropTop, cropRight, cropBottom, cropLeft

    var label: String {
      switch self {
      case .positionX: "Pos X"
      case .positionY: "Pos Y"
      case .scaleX: "Scale X"
      case .scaleY: "Scale Y"
      case .cropTop: "Crop Top"
      case .cropRight: "Crop Right"
      case .cropBottom: "Crop Bottom"
      case .cropLeft: "Crop Left"
      }
    }
  }

  static let identityStrings = ["0", "0", "1", "1", "0", "0", "0", "0"]

  var name = ""
  var isHidden = false
  var supportsPlacement = true
  /// Whether the layer's content can be cropped; only VFX Sources apply insets.
  var supportsCrop = false
  var strings = VideoLayersTableRowState.identityStrings
  var transform = Ldtx_Workspace_V4_BasicTransform()
  @ObservationIgnored private var displayedStrings = VideoLayersTableRowState.identityStrings
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
      cropPercentage(transform.topInset),
      cropPercentage(transform.rightInset),
      cropPercentage(transform.bottomInset),
      cropPercentage(transform.leftInset),
    ]
    displayedStrings = strings
    hasLocalTextChanges = false
  }

  /// Formats an inset, a fraction of the content size, as a percentage.
  private func cropPercentage(_ value: Ldtx_Workspace_V4_Rational32?) -> String {
    RationalFormatStyle(multiplier: 100).format(value ?? .init())
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

  var body: some View {
    HStack {
      Text(state.name).lineLimit(1)
      Spacer()
      Toggle(
        "Hide",
        isOn: Binding(get: { state.isHidden }, set: { state.onSetHidden($0, undoManager) })
      )
      .toggleStyle(.checkbox)
      .fixedSize()
    }
    .frame(minHeight: 24)
  }
}

struct VideoLayersPlacementEditor: View {
  @Environment(\.undoManager) private var undoManager
  @Bindable var state: VideoLayersTableRowState
  @FocusState private var focusedField: Int?

  var body: some View {
    Group {
      if state.supportsPlacement {
        VStack(alignment: .leading) {
          Grid(alignment: .leading) {
            fieldRow(.positionX, .positionY)
            fieldRow(.scaleX, .scaleY)
          }
          if state.supportsCrop {
            Text("Crop (%)").foregroundStyle(.secondary)
            Grid(alignment: .leading) {
              fieldRow(.cropTop, .cropBottom)
              fieldRow(.cropLeft, .cropRight)
            }
          }
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .writingToolsBehavior(.disabled)
      } else {
        Text("\(state.name) has no placement settings.").foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 2)
    .onChange(of: focusedField) { _, new in
      state.isEditing = new != nil
    }
    .onDisappear {
      state.isEditing = false
    }
  }

  private func fieldRow(
    _ first: VideoLayersTableRowState.Field, _ second: VideoLayersTableRowState.Field
  ) -> some View {
    GridRow {
      field(first)
      field(second)
    }
  }

  @ViewBuilder private func field(_ field: VideoLayersTableRowState.Field) -> some View {
    let index = field.rawValue
    Text(field.label).fixedSize()
    TextField(
      field.label,
      text: Binding(
        get: { state.strings[index] },
        set: {
          guard state.strings[index] != $0 else { return }
          state.edit($0, at: index, undoManager: undoManager)
        })
    )
    .labelsHidden()
    .focused($focusedField, equals: index)
    .frame(minWidth: 60)
  }
}
