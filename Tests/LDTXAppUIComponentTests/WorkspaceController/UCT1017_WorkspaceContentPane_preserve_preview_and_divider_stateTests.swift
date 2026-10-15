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
      #expect(view.superview === controller.pairedPreview)
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

    @Test("UCT-1017.1: Content reflects output failures through AppKit Observation")
    func editorsObserveStoreThroughAppKitLayout() async throws {
      let serviceAppletData = WorkspaceAppletData()
      _ = NSApplication.shared
      let service = WorkspaceStateService(definition: .init(), preferences: .init())
      let content = AudioMixEditor(
        stateService: service, appletData: serviceAppletData, peakMeter: .init(),
        reportError: { _ in })
      #expect(!content.isViewLoaded)
      service.outputFailureMessage = "Initial failure"
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = content
      window.orderFront(nil)
      defer { window.close() }
      window.contentView?.layoutSubtreeIfNeeded()
      #expect(content.outputErrorLabel.stringValue == "Initial failure")
      service.outputFailureMessage = "Updated failure"
      for _ in 0..<50 {
        if content.outputErrorLabel.stringValue == "Updated failure" { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(content.outputErrorLabel.stringValue == "Updated failure")
    }

    @Test("UCT-1017.2: Video tabs and audio selection remain independent and Window local")
    func contentTabsAndAudioTargetAreIndependentAndWindowLocal() {
      let first = makeWorkspaceTestWindow()
      let second = makeWorkspaceTestWindow()
      defer {
        first.close()
        second.close()
      }
      #expect(
        first.contentPane.testVideoTabs.tabViewItems.map(\.label) == [
          "Landscape Video Layers", "Portrait Video Layers",
        ])
      #expect(first.contentPane.testVideoTabs.selectedTabViewItemIndex == 0)
      #expect(
        first.contentPane.testAudioMixEditor.view.isDescendant(
          of: first.contentPane.view))
      first.contentPane.testVideoTabs.selectedTabViewItemIndex = 1
      #expect(first.contentPane.stateService.selectedAudioMix == .landscape)
      first.contentPane.stateService.selectedAudioMix = .portrait
      #expect(first.contentPane.stateService.selectedAudioMix == .portrait)
      #expect(first.contentPane.testVideoTabs.selectedTabViewItemIndex == 1)
      #expect(second.contentPane.testVideoTabs.selectedTabViewItemIndex == 0)
    }

    @Test("UCT-1017.3: Window shutdown stops the owned Preview renderer")
    func controllerOwnsAndStopsPreviewRenderer() async throws {
      _ = NSApplication.shared
      let document = WorkspaceDocument()
      defer { document.close() }
      let frameKey = "NSWindow Frame WorkspaceV4.AppKit.v1"
      let savedFrame = UserDefaults.standard.object(forKey: frameKey)
      defer {
        if let savedFrame {
          UserDefaults.standard.set(savedFrame, forKey: frameKey)
        } else {
          UserDefaults.standard.removeObject(forKey: frameKey)
        }
      }
      let controller = WorkspaceWindowController(
        stateService: document.stateService,
        persistenceCoordinator: document.persistenceCoordinator,
        appletData: WorkspaceAppletData(), document: document)
      document.addWindowController(controller)
      let window = try #require(controller.window as? WorkspaceTestWindow)
      #expect(
        window.contentPane.testPairedPreview.metalView.delegate === controller.previewRenderer)
      #expect(
        controller.windowRuntime.landscapeRuntime
          !== controller.windowRuntime.portraitRuntime)
      await controller.shutdown()
      #expect(window.contentPane.testPairedPreview.metalView.delegate == nil)
      #expect(window.contentPane.testPairedPreview.metalView.isPaused)
      window.close()
      document.close()
    }

    @Test("UCT-1017.4: Preview uses injected runtimes and its own Program selection")
    func contentPreviewUsesInjectedRuntimesAndTracksItsOwnProgram() {
      _ = NSApplication.shared
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let otherState = WorkspaceStateService(definition: .init(), preferences: .init())
      let first = makeWorkspaceTestWindow(stateService: state)
      let second = makeWorkspaceTestWindow(stateService: otherState)
      defer {
        first.close()
        second.close()
      }
      let firstPreview = first.contentPane.testPairedPreview
      let firstDelegate = firstPreview.metalView.delegate
      #expect(firstPreview !== second.contentPane.testPairedPreview)
      #expect(firstDelegate !== second.contentPane.testPairedPreview.metalView.delegate)
      #expect(
        first.contentPane.appletData.selectedProgram(
          in: first.contentPane.stateService.workspaceDefinition,
          for: first.contentPane.stateService.localStateURL) == nil)
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 42
      program.displayName = "Preview"
      state.workspaceDefinition.programs = [program]
      #expect(
        first.contentPane.appletData.selectedProgram(
          in: first.contentPane.stateService.workspaceDefinition,
          for: first.contentPane.stateService.localStateURL) != nil)
      #expect(
        second.contentPane.appletData.selectedProgram(
          in: second.contentPane.stateService.workspaceDefinition,
          for: second.contentPane.stateService.localStateURL) == nil)
      for value in [WorkspaceRecordingState.idle, .recording, .paused] {
        state.recordingState = value
        #expect(
          first.contentPane.appletData.selectedProgram(
            in: first.contentPane.stateService.workspaceDefinition,
            for: first.contentPane.stateService.localStateURL) != nil)
        #expect(first.contentPane.testPairedPreview === firstPreview)
        #expect(firstPreview.metalView.delegate === firstDelegate)
      }
      state.workspaceDefinition.programs = []
      #expect(
        first.contentPane.appletData.selectedProgram(
          in: first.contentPane.stateService.workspaceDefinition,
          for: first.contentPane.stateService.localStateURL) == nil)
    }

    @Test("UCT-1017.5: Preview selection and Divider position remain Window local")
    func appKitPreviewSelectionAndSplitPositionAreWindowLocal() throws {
      _ = NSApplication.shared
      let url = URL(fileURLWithPath: "/tmp/PreviewLayout-\(UUID()).ldtxworkspace")
      let suite = "PreviewLayout-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let definition = state.workspaceDefinition
      let preferences = state.workspacePreferences
      let outputSettings = state.workspaceOutputSettings
      let externalID = UUID().uuidString.lowercased()
      let dividerKey = "NSSplitView Subview Frames WorkspaceContentPane.\(externalID)"
      let savedDivider = UserDefaults.standard.object(forKey: dividerKey)
      defer {
        if let savedDivider {
          UserDefaults.standard.set(savedDivider, forKey: dividerKey)
        } else {
          UserDefaults.standard.removeObject(forKey: dividerKey)
        }
      }
      let first = makeWorkspaceTestWindow(
        stateService: state, appletData: data, url: url, externalID: externalID)
      defer { first.close() }
      let pane = first.contentPane
      #expect(!pane.testSplitView.isVertical)
      #expect(pane.testPairedPreview.metalView.delegate != nil)
      first.orderFront(nil)
      #expect(pane.testSplitView.arrangedSubviews[1] === pane.testEditorScrollView)
      #expect(pane.testEditorScrollView.hasVerticalScroller)
      pane.testSplitView.setPosition(pane.testSplitView.bounds.height - 80, ofDividerAt: 0)
      first.contentView?.layoutSubtreeIfNeeded()
      let editorDocument = try #require(pane.testEditorScrollView.documentView)
      #expect(editorDocument is NSStackView)
      #expect(editorDocument.isFlipped)
      #expect(editorDocument.frame.height > pane.testEditorScrollView.contentView.bounds.height)
      #expect(
        abs(editorDocument.frame.width - pane.testEditorScrollView.contentView.bounds.width) < 0.5)
      editorDocument.scroll(NSPoint(x: 0, y: editorDocument.frame.height))
      #expect(pane.testEditorScrollView.contentView.bounds.origin.y > 0)
      editorDocument.scroll(.zero)
      #expect(pane.testEditorScrollView.contentView.bounds.origin.y == 0)
      pane.testSplitView.setPosition(150, ofDividerAt: 0)
      first.contentView?.layoutSubtreeIfNeeded()
      pane.testPairedPreview.layout()
      let metalFrameInWindow = pane.testPairedPreview.metalView.convert(
        pane.testPairedPreview.metalView.bounds, to: nil)
      #expect(metalFrameInWindow.maxY <= first.contentLayoutRect.maxY + 0.5)
      pane.testPairedPreview.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
      pane.testPairedPreview.layout()
      let size = pane.testPairedPreview.metalView.bounds.size
      pane.testPairedPreview.selectCanvas(at: CGPoint(x: size.width - 20, y: size.height / 2))
      #expect(state.selectedAudioMix == .portrait)
      pane.testPairedPreview.selectCanvas(at: CGPoint(x: 20, y: size.height / 2))
      #expect(state.selectedAudioMix == .landscape)
      pane.testSplitView.setPosition(220, ofDividerAt: 0)
      first.contentView?.layoutSubtreeIfNeeded()
      let previewHeight = pane.testPairedPreview.frame.height
      #expect(
        pane.testSplitView.autosaveName == "WorkspaceContentPane.\(externalID)")
      first.setContentSize(NSSize(width: 1100, height: 800))
      first.contentView?.layoutSubtreeIfNeeded()
      #expect(abs(pane.testPairedPreview.frame.height - previewHeight) < 0.5)
      pane.testSplitView.setPosition(100, ofDividerAt: 0)
      first.contentView?.layoutSubtreeIfNeeded()
      #expect(editorDocument.frame.height < pane.testEditorScrollView.contentView.bounds.height)
      #expect(editorDocument.frame.minY == 0)
      #expect(pane.testEditorScrollView.contentView.bounds.minY == 0)
      let reopened = makeWorkspaceTestWindow(
        stateService: state, appletData: data,
        url: URL(fileURLWithPath: "/tmp/Renamed-\(UUID()).ldtxworkspace"), externalID: externalID)
      defer { reopened.close() }
      let split = reopened.contentPane.testSplitView
      #expect(split.autosaveName == pane.testSplitView.autosaveName)
      #expect(state.workspaceDefinition == definition)
      #expect(state.workspacePreferences == preferences)
      #expect(state.workspaceOutputSettings == outputSettings)
      pane.testPairedPreview.stop()
      #expect(pane.testPairedPreview.metalView.delegate == nil)
      #expect(pane.testPairedPreview.metalView.isPaused)
    }

    @Test("UCT-1017.6: Divider state restores and preserves user-adjusted height")
    func initialDividerRestoresAndPreservesDraggedHeight() throws {
      let externalID = UUID().uuidString.lowercased()
      let dividerKey = "NSSplitView Subview Frames WorkspaceContentPane.\(externalID)"
      let savedDivider = UserDefaults.standard.object(forKey: dividerKey)
      defer {
        if let savedDivider {
          UserDefaults.standard.set(savedDivider, forKey: dividerKey)
        } else {
          UserDefaults.standard.removeObject(forKey: dividerKey)
        }
      }
      let first = makeWorkspaceTestWindow(externalID: externalID)
      defer { first.close() }
      first.orderFront(nil)
      first.contentView?.layoutSubtreeIfNeeded()
      let split = first.contentPane.testSplitView
      #expect(abs(split.arrangedSubviews[0].frame.height - 280) < 0.5)

      let initialHeight = split.arrangedSubviews[0].frame.height
      let start = NSPoint(x: split.bounds.midX, y: initialHeight + split.dividerThickness / 2)
      let end = NSPoint(x: start.x, y: 360 + split.dividerThickness / 2)
      let timestamp = ProcessInfo.processInfo.systemUptime
      let down = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: split.convert(start, to: nil), modifierFlags: [],
          timestamp: timestamp, windowNumber: first.windowNumber, context: nil,
          eventNumber: 1, clickCount: 1, pressure: 1))
      for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
        let event = try #require(
          NSEvent.mouseEvent(
            with: type, location: split.convert(end, to: nil), modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: first.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        NSApplication.shared.postEvent(event, atStart: false)
      }
      split.mouseDown(with: down)
      first.contentView?.layoutSubtreeIfNeeded()
      let draggedHeight = split.arrangedSubviews[0].frame.height
      #expect(abs(draggedHeight - 360) < 1)

      for height: CGFloat in [800, 700] {
        first.setContentSize(NSSize(width: 1062, height: height))
        first.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(split.arrangedSubviews[0].frame.height - draggedHeight) < 0.5)
      }
      first.close()
      let reopened = makeWorkspaceTestWindow(externalID: externalID)
      defer { reopened.close() }
      reopened.orderFront(nil)
      reopened.contentView?.layoutSubtreeIfNeeded()
      #expect(
        abs(reopened.contentPane.testPairedPreview.frame.height - draggedHeight) < 1)
      reopened.setContentSize(NSSize(width: 1100, height: 850))
      reopened.contentView?.layoutSubtreeIfNeeded()
      #expect(
        abs(reopened.contentPane.testPairedPreview.frame.height - draggedHeight) < 1)
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
