// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct ProgramRenamePopover: View {
    @Binding private var name: String
    private var currentName: String
    private var renameProgram: () -> Void

    public init(
        name: Binding<String>,
        currentName: String,
        renameProgram: @escaping () -> Void
    ) {
        _name = name
        self.currentName = currentName
        self.renameProgram = renameProgram
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmedName.isEmpty && trimmedName != currentName
    }

    public var body: some View {
        TextField("Program Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("renameProgramNameField")
            .onSubmit {
                if canRename {
                    renameProgram()
                }
            }
            .padding(12)
            .frame(width: 260)
    }
}

#if DEBUG
#Preview("Program Rename Popover") {
    @Previewable @State var name = "Weekly Show"

    ProgramRenamePopover(
        name: $name,
        currentName: "Demo Program",
        renameProgram: {}
    )
}
#endif
