// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXProtosMacOSExtra
import LDTXRichText
import LDTXVariableMacro
import LDTXWorkspaceAppletModel
import SwiftUI

struct DynamicTextInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let internalID: Int64

  @State private var editorError: String?

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
          if let document = try? LDTXRichTextDocument(rtfd: component.rtfdDocument) {
            let keys = [LDTXVariableKey: String](definition: stateService.workspaceDefinition).keys
              .sorted {
                $0.path < $1.path
              }.map { LDTXVariableReference(id: $0.id, sel: $0.sel) }
            LDTXVariableMacroEditor(
              document: document,
              keys: keys,
              name: { key in
                let name = stateService.workspaceDefinition.visions.first {
                  $0.internalID.map(String.init) == key.id
                }?.displayName
                return "\(name ?? key.id) — \(key.sel)"
              },
              onDocumentChange: {
                documentBinding(fallback: document).wrappedValue = $0
                editorError = nil
              },
              onError: { editorError = $0.localizedDescription }
            )
            .id(internalID)
            .frame(minHeight: 120)
            Text(
              keys.isEmpty
                ? "Add a Vision to make variables available."
                : "Right-click the text to insert a variable. Click a variable to replace it."
            )
            .font(.caption).foregroundStyle(.secondary)
          } else {
            Text("This rich text document is invalid or unsupported.").foregroundStyle(
              .secondary)
          }
          Text("Variables update automatically after saving the Workspace.")
            .font(.caption).foregroundStyle(.secondary)
          if let editorError { Text(editorError).foregroundStyle(.red) }
        }
      } else {
        Text("This item is no longer present in the Workspace.")
      }
      VideoComponentDeleteButton(stateService: stateService, componentID: internalID)
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
        stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition.videoComponents[index].dynamicText = value
        }
      })
  }

  private func documentBinding(fallback: LDTXRichTextDocument) -> Binding<
    LDTXRichTextDocument
  > {
    Binding(
      get: {
        component.flatMap { try? LDTXRichTextDocument(rtfd: $0.rtfdDocument) } ?? fallback
      },
      set: { next in
        guard !stateService.isOutputActive, var value = component,
          let index = stateService.workspaceDefinition.videoComponents.firstIndex(where: {
            $0.internalID == internalID
          })
        else { return }
        value.rtfdDocument = next.rtfd
        stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition.videoComponents[index].dynamicText = value
        }
      })
  }
}
