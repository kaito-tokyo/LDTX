// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import SwiftUI
import Testing

@MainActor
private final class Probe {
  var appeared = false
  var readURL: () -> URL? = { nil }
}

private struct ProbeView: View {
  weak var document: NSDocument?
  let probe: Probe

  var body: some View {
    Text("Explicit Document")
      .onAppear {
        probe.readURL = { [weak document] in document?.fileURL }
        probe.appeared = true
      }
  }
}

extension AppUIComponentTestSuite {
  @Suite("UCT-1022: inject-document-explicitly", .serialized)
  @MainActor
  struct UCT1022DocumentReferenceIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private func host(_ document: NSDocument?, probe: Probe) async throws -> NSWindow {
      _ = NSApplication.shared
      let root = VStack { ProbeView(document: document, probe: probe) }
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(rootView: root)
      window.orderFront(nil)
      for _ in 0..<100 where !probe.appeared { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.appeared)
      return window
    }

    @Test("LUB-1030: UCT-1022.1: Nested views follow their own document URL")
    func nestedViewsReadCurrentURLAndDocumentsRemainSeparate() async throws {
      let first = NSDocument()
      let second = NSDocument()
      let firstReference = first
      let secondReference = second
      let firstProbe = Probe()
      let secondProbe = Probe()
      let firstWindow = try await host(firstReference, probe: firstProbe)
      let secondWindow = try await host(secondReference, probe: secondProbe)
      defer {
        firstWindow.close()
        secondWindow.close()
        first.close()
        second.close()
      }
      #expect(firstProbe.readURL() == nil)
      first.fileURL = URL(fileURLWithPath: "/tmp/First.ldtxworkspace")
      second.fileURL = URL(fileURLWithPath: "/tmp/Second.ldtxrecord")
      #expect(firstProbe.readURL() == first.fileURL)
      #expect(secondProbe.readURL() == second.fileURL)
      first.fileURL = URL(fileURLWithPath: "/tmp/Moved.ldtxworkspace")
      #expect(firstProbe.readURL() == first.fileURL)
      #expect(secondProbe.readURL() == second.fileURL)
    }

    @Test("LUB-1030: UCT-1022.2: Hosted views do not retain the Document")
    func hostedViewsDoNotOwnDocument() async throws {
      var document: NSDocument? = NSDocument()
      weak var weakDocument = document
      let probe = Probe()
      let window = try await host(document, probe: probe)
      defer { window.close() }
      document = nil
      #expect(weakDocument == nil)
      #expect(probe.readURL() == nil)
      #expect(window.contentViewController != nil)
    }

    @Test("LUB-1030: UCT-1022.3: A missing Explicit Document is safe")
    func missingEnvironmentIsSafe() async throws {
      let probe = Probe()
      let window = try await host(nil, probe: probe)
      defer { window.close() }
      #expect(probe.readURL() == nil)
    }
  }
}
