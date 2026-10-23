// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct ClockInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
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
    .disabled(isRecording || stateService.isClosed)
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
      }
      Section("Text Outlines") {
        ForEach(component.outlines.indices, id: \.self) { index in
          VStack(alignment: .leading) {
            Text("Outline \(index + 1)").font(.headline)
            ColorPicker(
              "Color", selection: outlineColorBinding(at: index, undoManager: undoManager),
              supportsOpacity: true)
            ClockOutlineWidthField(
              value: outlineBinding(
                at: index, \.thickness, initial: component.outlines[index].thickness,
                undoManager: undoManager))
            HStack {
              Spacer()
              Button("Remove Outline", role: .destructive) {
                removeOutline(at: index, undoManager: undoManager)
              }
            }
          }
        }
        // Membership changes discard row-local drafts and focus, including through Undo/Redo.
        .id(component.outlines.count)
        Button("Add Outline", systemImage: "plus") {
          addOutline(undoManager: undoManager)
        }
        .disabled(component.outlines.count >= 2)
        Text(
          "Up to two outlines, ordered from back to front. New widths must be from 0 to 64 pixels."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    } else {
      Section("Clock") {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }

  }

  func outlineBinding<Value>(
    at index: Int, _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_ClockTextOutline, Value>,
    initial: Value, undoManager: UndoManager?
  ) -> Binding<Value> {
    Binding(
      get: {
        guard let component, component.outlines.indices.contains(index) else { return initial }
        return component.outlines[index][keyPath: keyPath]
      },
      set: { next in
        editOutlines(undoManager: undoManager) { outlines in
          guard outlines.indices.contains(index) else { return }
          outlines[index][keyPath: keyPath] = next
        }
      })
  }

  func outlineColorBinding(at index: Int, undoManager: UndoManager?) -> Binding<Color> {
    let binding = outlineBinding(
      at: index, \.extendedSrgbColor, initial: .init(), undoManager: undoManager)
    return Binding(
      get: { binding.wrappedValue.extendedSRGBSwiftUIColor ?? .clear },
      set: { next in
        guard let color = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: next) else { return }
        binding.wrappedValue = color
      })
  }

  func addOutline(undoManager: UndoManager?) {
    editOutlines(undoManager: undoManager) { outlines in
      guard outlines.count < 2 else { return }
      outlines.append(
        .with {
          $0.thickness = .with { $0.set(num: 1, den: 1) }
          $0.extendedSrgbColor = .with { $0.alpha = 1 }
        })
    }
  }

  func removeOutline(at index: Int, undoManager: UndoManager?) {
    editOutlines(undoManager: undoManager) { outlines in
      guard outlines.indices.contains(index) else { return }
      outlines.remove(at: index)
    }
  }

  private func editOutlines(
    undoManager: UndoManager?,
    _ mutation: (inout [Ldtx_Workspace_V4_ClockTextOutline]) -> Void
  ) {
    updateVideoComponent(undoManager: undoManager) { wrapper in
      guard case .clock(var value) = wrapper.videoComponent else { return }
      mutation(&value.outlines)
      wrapper.videoComponent = .clock(value)
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
        .labelsHidden()
        .multilineTextAlignment(.trailing).frame(width: 90).disabled(isRecording)
    }
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    updateVideoComponent(undoManager: undoManager, mutation)
  }

  private func updateVideoComponent(
    undoManager: UndoManager?,
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    guard !stateService.isOutputActive, !stateService.isClosed else { return }
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == internalID })
    else { return }
    mutation(&definition.videoComponents[index])
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
  }

}

/// The renderer caps outlines at 64 pixels. Preserve older saved values until edited.
private struct ClockOutlineWidthField: View {
  @Binding var value: Ldtx_Workspace_V4_Rational32
  @State private var draft = ""
  @State private var hasInvalidDraft = false
  @FocusState private var isFocused: Bool

  var body: some View {
    LabeledContent("Width (pixels)") {
      TextField(
        "Width (pixels)",
        text: Binding(
          get: { draft },
          set: { text in
            draft = text
            guard let parsed = try? RationalParseStrategy().parse(text),
              (0...64).contains(parsed.double)
            else {
              hasInvalidDraft = true
              return
            }
            hasInvalidDraft = false
            value = parsed
          })
      )
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(width: 90)
      .focused($isFocused)
    }
    .onChange(of: value, initial: true) { _, next in
      guard !isFocused || !hasInvalidDraft else { return }
      // Preserve valid typing such as "3." while following external Undo/Redo.
      if !isFocused || (try? RationalParseStrategy().parse(draft)) != next {
        draft = RationalFormatStyle().format(next)
      }
    }
    if hasInvalidDraft {
      Text("Enter a width from 0 to 64 pixels. The last accepted width is unchanged.")
        .font(.caption).foregroundStyle(.secondary)
    } else if value.double > 64 {
      Text("This saved width renders at 64 pixels. Enter 0–64 to change it.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
