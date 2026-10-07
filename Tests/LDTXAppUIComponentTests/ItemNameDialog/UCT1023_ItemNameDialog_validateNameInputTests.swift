// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1023: Name input validation")
  @MainActor
  struct UCT1023ItemNameDialogUnitTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("UCT-1023.1: Whitespace is removed from a valid candidate")
    func normalizesValidCandidate() {
      let dialog = makeDialog("  Camera  \n")
      #expect(dialog.candidate == "Camera")
      #expect(dialog.canSubmit)
      _ = dialog.body
    }

    @Test("UCT-1023.2: An empty candidate cannot be submitted")
    func rejectsEmptyCandidate() {
      let dialog = makeDialog(" \n  ")
      #expect(dialog.candidate.isEmpty)
      #expect(!dialog.canSubmit)
    }

    @Test("UCT-1023.3: An existing name cannot be submitted")
    func rejectsDuplicateCandidate() {
      let dialog = makeDialog(" Taken \n")
      #expect(dialog.candidate == "Taken")
      #expect(!dialog.canSubmit)
    }

    private func makeDialog(_ name: String) -> ItemNameDialog {
      ItemNameDialog(
        name: .constant(name), title: "Add Input", fieldTitle: "Name",
        isNameAvailable: { $0 != "Taken" }, submit: { _ in }, cancel: {})
    }
  }
}
