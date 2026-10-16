// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import MetalKit
import Observation
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1017: preserve-preview-and-divider-state", .serialized)
  @MainActor
  struct UCT1017WorkspaceContentPaneIntegrationTestSuite {
    @Test func hostingAndToolbarReleaseTheirController() async {
      weak var released: WorkspaceViewController?
      autoreleasepool {
        let window = makeWorkspaceTestWindow()
        released = window.content
        window.close()
        window.contentViewController = nil
      }
      for _ in 0..<50 {
        if released == nil { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
      #expect(released == nil)
    }
    @Test func unrepresentedDocumentReleasesItsResourceRegistration() {
      var released: [UUID] = []
      var document: WorkspaceDocument? = WorkspaceDocument {
        released.append($0)
      }
      let id = document!.runtimeID
      #expect(id != WorkspaceDocument().runtimeID)
      #expect(released.isEmpty)
      document = nil
      #expect(released == [id])
    }

    @Test func injectedResourcesStayRegisteredUntilShutdownAndReleaseOnce() async {
      let resources = WorkspaceRuntimeFixture()
      var released: [UUID] = []
      let document = WorkspaceDocument { id in
        #expect(resources.metalView.isPaused)
        #expect(resources.metalView.delegate == nil)
        #expect(resources.metalView.superview == nil)
        released.append(id)
      }
      let controller = WorkspaceWindowController(
        document: document, appletData: WorkspaceAppletData(),
        landscapeRuntime: resources.landscape, portraitRuntime: resources.portrait,
        metalView: resources.metalView, captureSessionCoordinator: resources.capture,
        lowFrequencyUpdateRegistry: resources.updates)
      let view = controller.pairedPreview.metalView
      #expect(view === resources.metalView)
      #expect(controller.windowRuntime.landscapeRuntime === resources.landscape)
      #expect(controller.windowRuntime.portraitRuntime === resources.portrait)
      #expect(controller.windowRuntime.captureSessionCoordinator === resources.capture)
      #expect(view.delegate === controller.previewRenderer)
      #expect(released.isEmpty)
      await controller.shutdown()
      #expect(view.isPaused)
      #expect(view.delegate == nil)
      #expect(view.superview == nil)
      #expect(released == [document.runtimeID])
      await controller.shutdown()
      #expect(released == [document.runtimeID])
    }

    @Test func runtimeOwnsCleanupAfterDocumentIsReleased() {
      var released: [UUID] = []
      var document: WorkspaceDocument? = WorkspaceDocument { released.append($0) }
      let id = document!.runtimeID
      weak var retained = document
      let finishShutdown = document!.claimRuntimeResources()
      document = nil
      #expect(retained == nil)
      #expect(released.isEmpty)
      finishShutdown()
      #expect(released == [id])
    }

    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("SwiftUI preview keeps its Metal surface through layout and tab changes")
    func previewIdentityAndCanvasSelection() async throws {
      let first = makeWorkspaceTestWindow()
      let second = makeWorkspaceTestWindow()
      defer {
        first.close()
        second.close()
      }
      first.orderFront(nil)
      await settleWorkspaceToolbar(first)
      let pane = first.contentPane
      let preview = pane.pairedPreview
      let metal = preview.metalView
      let delegate = metal.delegate
      #expect(metal.superview != nil)
      #expect(metal.bounds.width > 0)
      #expect(preview !== second.contentPane.pairedPreview)
      pane.layout.isPortrait = true
      #expect(!second.contentPane.layout.isPortrait)
      #expect(first.stateService.selectedAudioMix == .landscape)
      preview.selectCanvas(at: .init(x: metal.bounds.width - 1, y: metal.bounds.height / 2))
      #expect(first.stateService.selectedAudioMix == .portrait)
      preview.selectCanvas(at: .init(x: 1, y: metal.bounds.height / 2))
      #expect(first.stateService.selectedAudioMix == .landscape)
      for height: CGFloat in [100, 360, 200] {
        pane.layout.resizePreview(to: height)
        first.setContentSize(.init(width: 1100, height: 800))
        await settleWorkspaceToolbar(first)
        #expect(pane.pairedPreview.metalView === metal)
        #expect(metal.delegate === delegate)
        #expect(metal.bounds.height > 0)
      }
      preview.stop()
      #expect(metal.delegate == nil && metal.isPaused)
    }

    @Test("SwiftUI editors scroll when the lower pane shrinks")
    func editorsScrollAndObserveOutputFailures() async throws {
      let window = makeWorkspaceTestWindow()
      defer { window.close() }
      window.orderFront(nil)
      window.contentPane.layout.resizePreview(to: 600)
      await settleWorkspaceToolbar(window)
      let all = workspaceDescendants(window.contentView!)
      let scrolls = all.compactMap { $0 as? NSScrollView }
      #expect(
        scrolls.contains {
          ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height
        })
      let scroll = try #require(
        scrolls.first {
          workspaceDescendants($0).contains { $0 is AudioPeakMeterMTKView }
        })
      let document = try #require(scroll.documentView)
      let initialHeight = document.frame.height
      window.stateService.outputFailureMessage = "Visible failure"
      await settleWorkspaceToolbar(window)
      #expect(document.frame.height > initialHeight)
      scroll.contentView.scroll(
        to: .init(
          x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
      scroll.reflectScrolledClipView(scroll.contentView)
      await settleWorkspaceToolbar(window)
      #expect(scroll.contentView.bounds.origin.y > 0)
    }

    @Test("Preview height follows late snapshot adoption and persists by external ID")
    func previewHeightFollowsLateSnapshotAdoption() async throws {
      let transientID = UUID().uuidString.lowercased()
      let savedID = UUID().uuidString.lowercased()
      let transientKey = "WorkspaceContentPane.\(transientID).previewHeight"
      let savedKey = "WorkspaceContentPane.\(savedID).previewHeight"
      defer {
        UserDefaults.standard.removeObject(forKey: transientKey)
        UserDefaults.standard.removeObject(forKey: savedKey)
      }
      UserDefaults.standard.set(360.0, forKey: savedKey)
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let window = makeWorkspaceTestWindow(stateService: state, externalID: transientID)
      defer { window.close() }
      window.orderFront(nil)
      await settleWorkspaceToolbar(window)
      let layout = window.contentPane.layout
      let metal = window.contentPane.pairedPreview.metalView
      layout.resizePreview(to: 300)
      var snapshot = state.editingWorkspace
      snapshot.definitionExternalID = savedID
      state.replaceEditingWorkspace(snapshot)
      await settleWorkspaceToolbar(window)
      #expect(layout.previewHeight == 360)
      #expect(window.contentPane.pairedPreview.metalView === metal)
      layout.resizePreview(to: 340)
      #expect(UserDefaults.standard.double(forKey: savedKey) == 340)
      #expect(UserDefaults.standard.double(forKey: transientKey) == 300)
      let reopened = WorkspaceContentLayout()
      reopened.restore(externalID: savedID)
      #expect(reopened.previewHeight == 340)
      state.replaceEditingWorkspace(snapshot)
      await settleWorkspaceToolbar(window)
      #expect(layout.previewHeight == 340)
    }

    @Test("Legacy AppKit divider height migrates once and never overrides a new value")
    func migratesLegacyPreviewHeight() {
      let id = UUID().uuidString.lowercased()
      let legacyKey = "NSSplitView Subview Frames WorkspaceContentPane.\(id)"
      let key = "WorkspaceContentPane.\(id).previewHeight"
      defer {
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: key)
      }
      UserDefaults.standard.set(
        [
          "0.000000, 0.000000, 480.000000, 360.000000, NO, NO",
          "0.000000, 361.000000, 480.000000, 339.000000, NO, NO",
        ], forKey: legacyKey)
      let layout = WorkspaceContentLayout()
      layout.restore(externalID: id)
      #expect(layout.previewHeight == 360)
      #expect(UserDefaults.standard.double(forKey: key) == 360)
      layout.resizePreview(to: 320)
      let reopened = WorkspaceContentLayout()
      reopened.restore(externalID: id)
      #expect(reopened.previewHeight == 320)
      UserDefaults.standard.removeObject(forKey: key)
      UserDefaults.standard.set(["invalid"], forKey: legacyKey)
      let invalid = WorkspaceContentLayout()
      invalid.restore(externalID: id)
      #expect(invalid.previewHeight == 280)
    }

    @Test("UCT-1017.7: A new Workspace preserves its initial content size")
    func newWorkspacePreservesInitialContentSize() async throws {
      _ = NSApplication.shared
      let frameKey = "NSWindow Frame WorkspaceV4.AppKit.v1"
      let savedFrame = UserDefaults.standard.object(forKey: frameKey)
      UserDefaults.standard.removeObject(forKey: frameKey)
      defer {
        if let savedFrame {
          UserDefaults.standard.set(savedFrame, forKey: frameKey)
        } else {
          UserDefaults.standard.removeObject(forKey: frameKey)
        }
      }
      let document = WorkspaceDocument()
      document.makeWindowControllers()
      let window = try #require(document.windowControllers.first?.window)
      let contentSize = window.contentRect(forFrameRect: window.frame).size
      let visibleFrame = try #require(window.screen).visibleFrame
      let availableSize = window.contentRect(forFrameRect: visibleFrame).size
      #expect(contentSize.width >= min(1062, availableSize.width))
      #expect(contentSize.height >= min(700, availableSize.height))
      await document.shutdown()
      document.close()
    }
    @Test("UCT-1017.8: Output status preserves failure information")
    func storesOutputStatusForWorkspaceUI() {
      let stateService = WorkspaceStateService(definition: .init(), preferences: .init())

      stateService.isOutputActive = true
      stateService.isLocalRecording = true
      stateService.outputFailureMessage = nil

      #expect(stateService.isOutputActive)
      #expect(stateService.isLocalRecording)
      #expect(stateService.outputFailureMessage == nil)

      stateService.isOutputActive = false
      stateService.isLocalRecording = false
      stateService.outputFailureMessage = "Output failed."

      #expect(!stateService.isOutputActive)
      #expect(!stateService.isLocalRecording)
      #expect(stateService.outputFailureMessage == "Output failed.")
    }
  }
}
