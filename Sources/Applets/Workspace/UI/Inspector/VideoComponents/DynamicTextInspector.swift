// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import LDTXVariableMacro
import LDTXVariableStore
import SwiftUI

struct DynamicTextInspector: View {
  let stateService: WorkspaceStateService
  let appletData: WorkspaceAppletData
  let internalID: Int64

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: internalID)
      if let component {
        Section("Dynamic Text") {
          TextField("Name", text: binding(\.displayName, fallback: component.displayName))
          LabeledContent("Width") {
            TextField(
              "Width", value: binding(\.width, fallback: component.width),
              format: RationalFormatStyle())
          }
          LabeledContent("Height") {
            TextField(
              "Height", value: binding(\.height, fallback: component.height),
              format: RationalFormatStyle())
          }
          if let document = try? VariableMacroDocument(component: component) {
            VariableMacroEditor(
              document: documentBinding(fallback: document),
              keys: VariableStore(definition: stateService.workspaceDefinition).keys.sorted {
                $0.path < $1.path
              },
              name: { key in
                let name = stateService.workspaceDefinition.visions.first {
                  $0.internalID == key.visionID
                }?.displayName
                return "\(name ?? String(key.visionID)) — \(key.item.rawValue)"
              }
            )
            .id(internalID)
          } else {
            Text("This macro contains an unsupported variable reference.").foregroundStyle(
              .secondary)
          }
          Text("Variables update automatically after saving the Workspace.")
            .font(.caption).foregroundStyle(.secondary)
          ColorPicker("Text Color", selection: colorBinding, supportsOpacity: true)
        }
      } else {
        Text("This item is no longer present in the Workspace.")
      }
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive)
  }

  private var component: Ldtx_Workspace_V4_DynamicTextComponent? {
    stateService.workspaceDefinition.videoComponents.first { $0.internalID == internalID }.flatMap {
      guard case .dynamicText(let text) = $0.videoComponent else { return nil }
      return text
    }
  }

  private func binding<T>(
    _ key: WritableKeyPath<Ldtx_Workspace_V4_DynamicTextComponent, T>, fallback: T
  ) -> Binding<T> {
    Binding(
      get: { component?[keyPath: key] ?? fallback },
      set: { next in
        guard !stateService.isOutputActive,
          let index = stateService.workspaceDefinition.videoComponents.firstIndex(where: {
            $0.internalID == internalID
          }),
          var value = component
        else { return }
        value[keyPath: key] = next
        stateService.workspaceDefinition.videoComponents[index].dynamicText = value
      })
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: {
        let color = component?.foregroundExtendedSrgbColor ?? .init()
        return Color(
          .sRGB, red: Double(color.red), green: Double(color.green), blue: Double(color.blue),
          opacity: Double(color.alpha))
      },
      set: { next in
        guard let rgb = NSColor(next).usingColorSpace(.sRGB) else { return }
        var color = Ldtx_Workspace_V4_Color()
        color.red = Float(rgb.redComponent)
        color.green = Float(rgb.greenComponent)
        color.blue = Float(rgb.blueComponent)
        color.alpha = Float(rgb.alphaComponent)
        binding(\.foregroundExtendedSrgbColor, fallback: color).wrappedValue = color
      })
  }

  private func documentBinding(fallback: VariableMacroDocument) -> Binding<VariableMacroDocument> {
    Binding(
      get: {
        component.flatMap { try? VariableMacroDocument(component: $0) } ?? fallback
      },
      set: { next in
        guard !stateService.isOutputActive, var value = component,
          let index = stateService.workspaceDefinition.videoComponents.firstIndex(where: {
            $0.internalID == internalID
          })
        else { return }
        value.macroDocument = next.xml
        value.clearText()
        stateService.workspaceDefinition.videoComponents[index].dynamicText = value
      })
  }
}
