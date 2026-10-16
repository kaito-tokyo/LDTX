// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXVariableStore
import SwiftUI

/// Reads the observable Workspace runtime when SwiftUI evaluates the inspector.
public struct VariableStoreInspector: View {
  private let store: () -> VariableStore?

  public init(store: @escaping () -> VariableStore?) {
    self.store = store
  }

  private struct Entry: Identifiable {
    let key: VariableKey
    let value: Result<String, any Error>
    var id: VariableKey { key }
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Variables").font(.headline)
        if let store = store() {
          if store.keys.isEmpty {
            Text("No variables").foregroundStyle(.secondary)
            Text("Variables appear here when a saved Workspace defines Visions.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(
              store.keys.sorted { $0.path < $1.path }.map { key in
                Entry(key: key, value: Result(catching: { try store.read(key) }))
              }
            ) { entry in
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.key.path).font(.caption).foregroundStyle(.secondary)
                switch entry.value {
                case .success(let value):
                  Text(verbatim: value.isEmpty ? "\"\"" : value)
                    .font(.system(.body, design: .monospaced))
                    // Refresh selectable text and its accessibility value together.
                    .id(value)
                case .failure(let error):
                  Text(error.localizedDescription).foregroundStyle(.red)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        } else {
          Text("The Workspace runtime is unavailable.").foregroundStyle(.secondary)
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
