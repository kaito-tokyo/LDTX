// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
import Observation
import SwiftUI

protocol VideoLayersTableRowDelegate: AnyObject {
  @MainActor func videoLayersTableRowDidRequestCommit(_ row: VideoLayersTableRow)
  @MainActor func videoLayersTableRow(_ row: VideoLayersTableRow, setHidden hidden: Bool)
}

final class VideoLayersTableRow: NSHostingView<VideoLayersTableRowContent> {
  let state: VideoLayersTableRowState
  weak var delegate: (any VideoLayersTableRowDelegate)?

  required init(rootView: VideoLayersTableRowContent) {
    state = rootView.state
    super.init(rootView: rootView)
    sizingOptions = .intrinsicContentSize
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // The name band belongs to the table; the controls belong to SwiftUI.
    let localPoint = convert(point, from: superview)
    guard bounds.contains(localPoint),
      localPoint.y >= bounds.minY + VideoLayersTableView.dragRegionHeight
    else { return nil }
    return super.hitTest(point)
  }
}

@MainActor @Observable final class VideoLayersTableRowState {
  @ObservationIgnored var onCommit: () -> Void = {}
  @ObservationIgnored var onSetHidden: (Bool) -> Void = { _ in }
  var name = ""
  var isHidden = false
  var strings = ["0.0", "0.0", "0.0", "0.0"]
  var hasUnconfirmedChanges = false
  var isEditing = false

  func display(
    _ transform: Ldtx_Workspace_V4_BasicTransform, canvasWidth: Double, canvasHeight: Double
  ) {
    strings = [
      String(Double(transform.translationX) * canvasWidth),
      String(Double(transform.translationY) * canvasHeight),
      String(transform.scaleX), String(transform.scaleY),
    ]
  }

}

struct VideoLayersTableRowContent: View {
  @Bindable var state: VideoLayersTableRowState
  let canvasWidth: Double
  let canvasHeight: Double
  @FocusState private var focusedField: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(state.name).lineLimit(1)
        Spacer()
      }
      .frame(height: VideoLayersTableView.dragRegionHeight)
      HStack {
        Toggle(
          "Hide", isOn: Binding(get: { state.isHidden }, set: { state.onSetHidden($0) })
        )
        .toggleStyle(.checkbox)
        ForEach(0..<4) { index in
          Text(["Pos X", "Pos Y", "Scale X", "Scale Y"][index])
          TextField(
            ["Pos X", "Pos Y", "Scale X", "Scale Y"][index],
            text: Binding(
              get: { state.strings[index] },
              set: {
                guard state.strings[index] != $0 else { return }
                state.strings[index] = $0
                state.hasUnconfirmedChanges = true
              })
          )
          .focused($focusedField, equals: index)
        }
      }
    }
    .textFieldStyle(.roundedBorder)
    .autocorrectionDisabled()
    .writingToolsBehavior(.disabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 2)
    .onSubmit { state.onCommit() }
    .onChange(of: focusedField) { _, new in
      state.isEditing = new != nil
    }
  }
}

#if DEBUG
  #Preview("Video Layers Table Row", traits: .fixedLayout(width: 720, height: 160)) {
    let state = VideoLayersTableRowState()
    state.name = "Camera"
    state.strings = ["192.0", "270.0", "1.0", "1.0"]
    let row = VideoLayersTableRow(
      rootView: VideoLayersTableRowContent(
        state: state, canvasWidth: 1920, canvasHeight: 1080))
    let preview = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    preview.addSubview(row)
    NSLayoutConstraint.activate([
      preview.widthAnchor.constraint(equalToConstant: 720),
      preview.heightAnchor.constraint(equalToConstant: 160),
      row.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: preview.safeAreaLayoutGuide.topAnchor, constant: 12),
      row.bottomAnchor.constraint(equalTo: preview.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
    return preview
  }
#endif
