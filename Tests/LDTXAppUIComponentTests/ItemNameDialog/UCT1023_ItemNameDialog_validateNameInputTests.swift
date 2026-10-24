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

    struct NameInput: Sendable, Codable {
      let input: String
      let candidate: String
      let canSubmit: Bool
    }

    @Test(
      "LUB-1048: UCT-1023.1–3: Name input determines the normalized candidate and submission",
      arguments: [
        NameInput(input: "  Camera  \n", candidate: "Camera", canSubmit: true),
        NameInput(input: " \n  ", candidate: "", canSubmit: false),
        NameInput(input: " Taken \n", candidate: "Taken", canSubmit: false),
      ])
    func validatesCandidate(_ data: NameInput) {
      let dialog = makeDialog(data.input)
      #expect(dialog.candidate == data.candidate)
      #expect(dialog.canSubmit == data.canSubmit)
    }

    private func makeDialog(_ name: String) -> ItemNameDialog {
      ItemNameDialog(
        name: .constant(name), title: "Add Input", fieldTitle: "Name",
        isNameAvailable: { $0 != "Taken" }, submit: { _ in }, cancel: {})
    }
  }
}
