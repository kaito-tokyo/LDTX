// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXDeviceRegistry
import LDTXVariableStore
@testable import LDTXWorkspaceAppletUI
import Observation
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("Variable Store Inspector", .serialized)
  @MainActor
  struct VariableStoreInspectorIntegrationTestSuite {
    @Observable final class Runtime {
      var store = VariableStore(keys: [
        .init(visionID: 11, item: .text), .init(visionID: 22, item: .confidence),
      ])
    }

    init() { _ = UIComponentTestEnvironment.documentController }

    @Test func displaysLiveValuesAndRecreatedInventory() async throws {
      let runtime = Runtime()
      let state = WorkspaceStateService(
        definition: .init(), preferences: .init(),
        inspectorSelector: .init(kind: .variableStore))
      let hosting = NSHostingView(
        rootView: WorkspaceInspectorContainer(
          deviceRegistry: DeviceRegistryService(), stateService: state,
          appletData: WorkspaceAppletData(), variableStore: { runtime.store }))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
        styleMask: .titled, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = hosting
      window.orderFront(nil)

      func strings(_ element: Any) -> [String] {
        guard let node = element as? any NSAccessibilityProtocol else { return [] }
        return [node.accessibilityValue() as? String, node.accessibilityLabel()].compactMap { $0 }
          + (node.accessibilityChildren() ?? []).flatMap(strings)
      }
      func displayed() async -> String {
        await settleWorkspaceToolbar(window)
        return strings(hosting).joined(separator: "\n")
      }
      let initial = await displayed()
      #expect(initial.contains("visions/11/text"))
      #expect(initial.contains("\"\""))
      #expect(initial.split(separator: "\n").contains("0"))
      try runtime.store.update([
        .init(visionID: 11, item: .text): "recognized text",
        .init(visionID: 22, item: .confidence): "0.75",
      ])
      let updated = await displayed()
      #expect(updated.contains("recognized text"), "Displayed: \(updated)")
      #expect(updated.split(separator: "\n").contains("0.75"))
      runtime.store = VariableStore(keys: runtime.store.keys)
      let reset = await displayed()
      #expect(!reset.contains("recognized text"))
      #expect(reset.contains("\"\""))
      #expect(reset.split(separator: "\n").contains("0"))
      runtime.store = VariableStore(keys: [])
      let empty = await displayed()
      #expect(empty.contains("No variables"))
      #expect(!empty.contains("visions/11/text"))
    }
  }
}
