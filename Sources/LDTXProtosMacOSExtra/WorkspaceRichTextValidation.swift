// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import LDTXCorelibs
import LDTXRichText

extension Ldtx_Workspace_V4_WorkspaceDefinitionV4 {
  public func validateRichTextDocuments() throws {
    for wrapper in videoComponents {
      if case .dynamicText(let component) = wrapper.videoComponent {
        _ = try LDTXRichTextDocument(rtfd: component.rtfdDocument)
      }
    }
  }
}
