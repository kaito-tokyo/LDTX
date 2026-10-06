// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import SwiftUI
import Testing

@MainActor
private final class Probe {
  var appeared = false
  var reference: DocumentReference?
  var readURL: () -> URL? = { nil }
}

private struct ProbeView: View {
  @Environment(\.documentReference) private var reference
  let probe: Probe

  var body: some View {
    Text("Document environment")
      .onAppear {
        let reference = reference
        probe.reference = reference
        probe.readURL = { reference?.document?.fileURL }
        probe.appeared = true
      }
  }
}

extension AppUIComponentTestSuite {
  @Suite("UCT-1022: scope-document-environment", .serialized)
  @MainActor
  struct UCT1022DocumentReferenceIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private func host(_ reference: DocumentReference?, probe: Probe) async throws -> NSWindow {
      _ = NSApplication.shared
      let root = VStack { ProbeView(probe: probe) }.environment(\.documentReference, reference)
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

    @Test("UCT-1022.1: Nested views follow their own document URL")
    func nestedViewsReadCurrentURLAndDocumentsRemainSeparate() async throws {
      let first = NSDocument()
      let second = NSDocument()
      let firstReference = DocumentReference(first)
      let secondReference = DocumentReference(second)
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
      #expect(firstProbe.reference === firstReference)
      #expect(secondProbe.reference === secondReference)
      #expect(firstProbe.reference?.document === first)
      #expect(secondProbe.reference?.document === second)
      #expect(firstProbe.readURL() == nil)
      first.fileURL = URL(fileURLWithPath: "/tmp/First.ldtxworkspace")
      second.fileURL = URL(fileURLWithPath: "/tmp/Second.ldtxrecord")
      #expect(firstProbe.readURL() == first.fileURL)
      #expect(secondProbe.readURL() == second.fileURL)
      first.fileURL = URL(fileURLWithPath: "/tmp/Moved.ldtxworkspace")
      #expect(firstProbe.readURL() == first.fileURL)
      #expect(secondProbe.readURL() == second.fileURL)
    }

    @Test("UCT-1022.2: Hosted views do not retain the Document")
    func hostedViewsDoNotOwnDocument() async throws {
      var document: NSDocument? = NSDocument()
      weak var weakDocument = document
      let reference = DocumentReference(try #require(document))
      let probe = Probe()
      let window = try await host(reference, probe: probe)
      defer { window.close() }
      document = nil
      #expect(weakDocument == nil)
      #expect(reference.document == nil)
      #expect(probe.reference === reference)
      #expect(probe.readURL() == nil)
      #expect(window.contentViewController != nil)
    }

    @Test("UCT-1022.3: A missing Document environment is safe")
    func missingEnvironmentIsSafe() async throws {
      let probe = Probe()
      let window = try await host(nil, probe: probe)
      defer { window.close() }
      #expect(probe.reference == nil)
      #expect(probe.readURL() == nil)
    }
  }
}
