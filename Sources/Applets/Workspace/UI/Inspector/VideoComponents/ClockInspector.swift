// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct ClockInspector: View {
  let stateService: WorkspaceStateService
  let appletData: WorkspaceAppletData
  let internalID: Int64

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: internalID)
      formContent
      VideoComponentDeleteButton(stateService: stateService, componentID: internalID)
    }
    .formStyle(.grouped)
    .disabled(isRecording)
  }

  @ViewBuilder
  private var formContent: some View {
    if let component {
      Section("Clock") {
        TextField("Name", text: componentBinding(\.displayName, initial: component.displayName))
          .disabled(isRecording)
        numericField(
          "Font Size", value: rationalBinding(\.fontSize, initial: component.fontSize))
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
        ColorPicker(
          "Foreground Color",
          selection: colorBinding(\.foregroundExtendedSrgbColor), supportsOpacity: true)
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
    stateService.workspaceDefinition.videoComponents.compactMap {
      wrapper -> Ldtx_Workspace_V4_ClockComponent? in
      guard case .clock(let component) = wrapper.videoComponent,
        component.internalID == internalID
      else { return nil }
      return component
    }.first
  }

  private var isRecording: Bool { stateService.isOutputActive }

  private func componentBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_ClockComponent, Value>, initial: Value
  ) -> Binding<Value> {
    Binding(
      get: { component?[keyPath: keyPath] ?? initial },
      set: { next in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.videoComponent else { return }
          value[keyPath: keyPath] = next
          wrapper.videoComponent = .clock(value)
        }
      }
    )
  }

  private func rationalBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_ClockComponent, Ldtx_Workspace_V4_Rational32>,
    initial: Ldtx_Workspace_V4_Rational32
  ) -> Binding<Ldtx_Workspace_V4_Rational32> {
    componentBinding(keyPath, initial: initial)
  }

  private func colorBinding(
    _ colorKeyPath: WritableKeyPath<
      Ldtx_Workspace_V4_ClockComponent, Ldtx_Workspace_V4_Color
    >
  ) -> Binding<Color> {
    Binding(
      get: { component?[keyPath: colorKeyPath].extendedSRGBSwiftUIColor ?? .clear },
      set: { next in
        guard let color = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: next) else { return }
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.videoComponent else { return }
          value[keyPath: colorKeyPath] = color
          wrapper.videoComponent = .clock(value)
        }
      }
    )
  }

  private var hasUtcOffsetBinding: Binding<Bool> {
    Binding(
      get: { component?.hasUtcOffsetMinutes ?? false },
      set: { enabled in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.videoComponent else { return }
          if enabled { value.utcOffsetMinutes = 0 } else { value.clearUtcOffsetMinutes() }
          wrapper.videoComponent = .clock(value)
        }
      }
    )
  }

  private var utcOffsetBinding: Binding<Int32> {
    Binding(
      get: { component?.utcOffsetMinutes ?? 0 },
      set: { next in
        updateVideoComponent { wrapper in
          guard case .clock(var value) = wrapper.videoComponent else { return }
          value.utcOffsetMinutes = next
          wrapper.videoComponent = .clock(value)
        }
      }
    )
  }

  private func numericField(_ title: String, value: Binding<Ldtx_Workspace_V4_Rational32>)
    -> some View
  {
    LabeledContent(title) {
      TextField(title, value: value, format: RationalFormatStyle())
        .multilineTextAlignment(.trailing).frame(width: 90).disabled(isRecording)
    }
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    guard !stateService.isOutputActive, !stateService.isClosed else { return }
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == internalID })
    else { return }
    mutation(&definition.videoComponents[index])
    stateService.workspaceDefinition = definition
  }

}
