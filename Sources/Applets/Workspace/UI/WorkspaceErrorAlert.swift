// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

private struct WorkspaceErrorAlert: ViewModifier {
  let stateService: WorkspaceStateService
  @State private var error: NSError?

  func body(content: Content) -> some View {
    content
      .onChange(of: stateService.operationErrors, initial: true) { _, errors in
        error = stateService.isClosed ? nil : errors.first
      }
      .alert(
        error?.localizedDescription ?? "",
        isPresented: Binding(
          get: { error != nil },
          set: { presented in
            guard !presented else { return }
            error = nil
            if !stateService.operationErrors.isEmpty { stateService.operationErrors.removeFirst() }
          })
      ) {
        Button("OK") {}
      } message: {
        Text(
          [error?.localizedFailureReason, error?.localizedRecoverySuggestion]
            .compactMap { $0 }.joined(separator: "\n\n"))
      }
  }
}

extension View {
  public func workspaceErrorAlert(stateService: WorkspaceStateService) -> some View {
    modifier(WorkspaceErrorAlert(stateService: stateService))
  }
}
