// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct VisionInputVideoComponentDropdown: View {
  let videoComponents: [Ldtx_Workspace_V4_VideoComponentWrapper]
  @Binding var selection: Int64?
  var title: LocalizedStringResource = "Video Component"

  private var options: [WorkspaceSelectionOption<Int64>] {
    videoComponents.compactMap {
      guard $0.canBeVisionInput, let id = $0.internalID, id > 0,
        let name = $0.displayName
      else { return nil }
      return .init(id: id, name: name)
    }
  }

  var body: some View {
    Picker(title, selection: $selection) {
      Text("Choose…").tag(Int64?.none).disabled(true)
      ForEach(options) { option in
        Text(option.name).tag(Optional(option.id))
      }
      if let selection, !options.contains(where: { $0.id == selection }) {
        Text("Unavailable").tag(Optional(selection))
      }
    }
    .pickerStyle(.menu)
  }
}
