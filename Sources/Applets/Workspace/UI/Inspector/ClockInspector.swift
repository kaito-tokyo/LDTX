// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct ClockInspector: View {
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let session: (any WorkspaceSessionProtocol)?
  let recordingSession: (any WorkspaceRecordingSessionProtocol)?

  var body: some View {
    if let component {
      Section("Clock") {
        TextField("Name", text: componentBinding(\.displayName, initial: component.displayName))
          .disabled(isRecording)
        numericField("Width", value: floatBinding(\.width, initial: component.width))
        numericField("Height", value: floatBinding(\.height, initial: component.height))
        Toggle("Show Date", isOn: componentBinding(\.showsDate, initial: component.showsDate))
        Toggle(
          "Show Seconds", isOn: componentBinding(\.showsSeconds, initial: component.showsSeconds))
        Toggle(
          "24-Hour Time",
          isOn: componentBinding(\.uses24HourTime, initial: component.uses24HourTime))
        Toggle("Use Fixed UTC Offset", isOn: hasUtcOffsetBinding)
        if component.hasUtcOffsetMinutes {
          LabeledContent("UTC Offset (minutes)") {
            TextField("Minutes", value: utcOffsetBinding, format: .number)
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
        }
        numericField(
          "Text Red",
          value: colorBinding(\.foregroundColor, \.red, initial: component.foregroundColor.red))
        numericField(
          "Text Green",
          value: colorBinding(\.foregroundColor, \.green, initial: component.foregroundColor.green))
        numericField(
          "Text Blue",
          value: colorBinding(\.foregroundColor, \.blue, initial: component.foregroundColor.blue))
        numericField(
          "Text Alpha",
          value: colorBinding(\.foregroundColor, \.alpha, initial: component.foregroundColor.alpha))
        LabeledContent("Text Outlines", value: "\(component.outlines.count)")
      }
    } else {
      Section("Clock") {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var component: Ldtx_Workspace_V4_ClockComponent? {
    uiState.definition.videoComponents.compactMap { wrapper -> Ldtx_Workspace_V4_ClockComponent? in
      guard case .clock(let component) = wrapper.definition,
        component.internalID == internalID
      else { return nil }
      return component
    }.first
  }

  private var isRecording: Bool { recordingSession?.isRecording ?? false }

  private func componentBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_ClockComponent, Value>, initial: Value
  ) -> Binding<Value> {
    Binding(
      get: { component?[keyPath: keyPath] ?? initial },
      set: { next in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.definition else { return }
          value[keyPath: keyPath] = next
          wrapper.definition = .clock(value)
        }
      }
    )
  }

  private func floatBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_ClockComponent, Float>, initial: Float
  ) -> Binding<Float> {
    componentBinding(keyPath, initial: initial)
  }

  private func colorBinding(
    _ colorKeyPath: WritableKeyPath<
      Ldtx_Workspace_V4_ClockComponent, Ldtx_Workspace_V4_ExtendedSrgbColor
    >,
    _ channel: WritableKeyPath<Ldtx_Workspace_V4_ExtendedSrgbColor, Float>,
    initial: Float
  ) -> Binding<Float> {
    Binding(
      get: { component.map { $0[keyPath: colorKeyPath][keyPath: channel] } ?? initial },
      set: { next in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.definition else { return }
          var color = value[keyPath: colorKeyPath]
          color[keyPath: channel] = next
          value[keyPath: colorKeyPath] = color
          wrapper.definition = .clock(value)
        }
      }
    )
  }

  private var hasUtcOffsetBinding: Binding<Bool> {
    Binding(
      get: { component?.hasUtcOffsetMinutes ?? false },
      set: { enabled in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.definition else { return }
          if enabled { value.utcOffsetMinutes = 0 } else { value.clearUtcOffsetMinutes() }
          wrapper.definition = .clock(value)
        }
      }
    )
  }

  private var utcOffsetBinding: Binding<Int32> {
    Binding(
      get: { component?.utcOffsetMinutes ?? 0 },
      set: { next in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.definition else { return }
          value.utcOffsetMinutes = next
          wrapper.definition = .clock(value)
        }
      }
    )
  }

  private func numericField(_ title: String, value: Binding<Float>) -> some View {
    LabeledContent(title) {
      TextField(title, value: value, format: .number.precision(.fractionLength(3)))
        .multilineTextAlignment(.trailing)
        .frame(width: 90)
        .disabled(isRecording)
    }
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: { wrapper in
        switch wrapper.id {
        case .solidColorFill(let id), .linearGradientFill(let id), .radialGradientFill(let id),
          .conicGradientFill(let id), .vfxSource(let id), .clock(let id), .testPattern(let id):
          id == internalID
        case .invalid:
          false
        }
      })
    else { return }
    mutation(&definition.videoComponents[index])
    uiState.definition = definition
  }

}
