// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
import LDTXProgramRuntime
import LDTXRichText
@testable import LDTXWorkspaceAppletService
import Testing

@MainActor
@Suite(.tags(.hard)) struct WorkspaceOverlayObservationIntegrationTestSuite {
  @Test("LUB-1054: Variable changes generate textures without any program runtime or frames")
  func variableChangesGenerateTexturesWithoutAnyProgramRuntimeOrFrames() async throws {
    let bundle = WorkspaceV4Bundle(
      definition: .with {
        $0.programs = [.with { $0.internalID = 100 }]
        $0.visions = [
          .with {
            $0.ocrVision = .with { $0.internalID = 11 }
          }
        ]
        $0.videoComponents = [
          .with {
            $0.dynamicText = .with {
              $0.internalID = 7
              $0.rtfdDocument = try! LDTXRichTextDocument(
                NSAttributedString(
                  attachment: LDTXVariableReference(id: "11", sel: "text").attachment())
              ).rtfd
              $0.width.set(num: 1, den: 2)
              $0.height.set(num: 1, den: 10)
            }
          }
        ]
      },
      preferences: .with {
        $0.landscapeProgramPreferences[100] = .with { $0.videoLayerInternalIds = [7] }
      })
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { bundle }, replaceWorkspace: { _ in })
    let workspace = WorkspaceWindowRuntime(
      persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
    defer { workspace.shutdown() }
    workspace.updateRuntimes()
    let store = workspace.landscapeOverlays.textures
    try await waitUntil { store.snapshot()["v4-7"] != nil }
    let blank = try #require(store.snapshot()["v4-7"])
    let context = workspace.visionFeatureContext
    context.reportVariables(11, [.text: "勝利"])
    try await waitUntil { store.snapshot()["v4-7"]?.colorTexture !== blank.colorTexture }
    let text = try #require(store.snapshot()["v4-7"])
    #expect(workspace.landscapeRuntime == nil)
    #expect(workspace.portraitRuntime == nil)

    // Successful adoption resets the observable variable inventory and the image.
    try persistence.adoptRuntimeWorkspace(bundle)
    try await waitUntil { store.snapshot()["v4-7"]?.colorTexture !== text.colorTexture }
    #expect(try workspace.readVariable(.init(visionID: 11, item: .text)).isEmpty)
    context.reportVariables(11, [.text: "stale"])
    #expect(try workspace.readVariable(.init(visionID: 11, item: .text)).isEmpty)

    workspace.shutdown()
    try await waitUntil { store.snapshot().isEmpty }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for independently generated overlay")
    throw CocoaError(.coderInvalidValue)
  }
}
