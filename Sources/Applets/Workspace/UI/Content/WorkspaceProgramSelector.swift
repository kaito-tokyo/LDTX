// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct WorkspaceProgramSelector: View {
  let options: [WorkspaceSelectionOption<UInt64>]
  @Binding var selection: UInt64

  var body: some View {
    Picker("Program", selection: $selection) {
      ForEach(options) { option in
        Text(option.name)
          .tag(option.id)
          .accessibilityIdentifier("workspaceProgramSelection-\(option.id)")
      }
    }
    .pickerStyle(.radioGroup)
    .horizontalRadioGroupLayout()
    .fixedSize(horizontal: true, vertical: false)
  }
}
