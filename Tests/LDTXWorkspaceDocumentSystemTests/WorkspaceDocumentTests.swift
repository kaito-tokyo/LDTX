// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAppletSupport
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftProtobuf
import Testing

@MainActor
private final class WorkspaceInitializingDocumentController: NSDocumentController {
  override func documentClass(forType typeName: String) -> AnyClass? { WorkspaceDocument.self }
}

@Suite(.serialized)
@MainActor
struct WorkspaceDocumentSystemTestSuite {
  private static let controller = WorkspaceInitializingDocumentController()

  init() { _ = Self.controller }

  @Test func saveValidationAggregatesErrorsWithoutCreatingAPackage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Invalid.ldtxworkspace")
    let document = WorkspaceDocument()
    defer { document.close() }
    document.storeService.definition.programs = [validationProgram(name: "Pattern")]
    document.storeService.definition.videoComponents = [validationPattern()]
    document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
      .videoLayerTransforms[2] = validationTransform(
        x: .with {
          $0.numerator = 2
          $0.denominator = 1
        })
    document.storeService.preferences.portraitProgramPreferences[1, default: .init()]
      .videoLayerTransforms[2] = validationTransform(
        scale: .with {
          $0.numerator = -1
          $0.denominator = 1
        })
    do {
      try await save(document, to: url)
      Issue.record("Expected validation failure")
    } catch let error as WorkspaceSaveValidationError {
      #expect(error.messages.count == 3)
      let alert = NSAlert(error: error)
      #expect(alert.informativeText.contains("Landscape"))
      #expect(alert.informativeText.contains("Portrait"))
      #expect(alert.informativeText.contains("Pattern"))
    }
    #expect(document.storeService.definition.displayName == "Untitled")
    #expect(document.fileURL == nil)
    #expect(document.isDocumentEdited)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func invalidSavePreservesFilesAndCorrectionRoundTripsDetachedPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Validated.ldtxworkspace")
    let document = WorkspaceDocument()
    defer { document.close() }
    document.storeService.definition.programs = [validationProgram(name: "Main")]
    document.storeService.definition.videoComponents = [validationPattern()]
    try await save(document, to: url)
    let before = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
    document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
      .videoLayerTransforms[2] = validationTransform(
        x: .with {
          $0.numerator = 2
          $0.denominator = 1
        })
    do {
      try await save(document, to: url, operation: .saveOperation)
      Issue.record("Expected validation failure")
    } catch is WorkspaceSaveValidationError {}
    #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == before)
    #expect(document.isDocumentEdited)
    document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
      .videoLayerTransforms[2] = validationTransform(
        x: .with {
          $0.numerator = 1
          $0.denominator = 2
        },
        scale: .with {
          $0.numerator = 1
          $0.denominator = 1
        })
    document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
      .videoLayerHidden[2] = true
    try await save(document, to: url, operation: .saveOperation)
    let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    defer { reopened.close() }
    #expect(reopened.storeService.preferences == document.storeService.preferences)
    #expect(reopened.storeService.definition.programs[0].landscapeVideoLayerInternalIds.isEmpty)
    #expect(!document.isDocumentEdited)
  }

  @Test func saveActionPresentsOneValidationSheet() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    document.addWindowController(NSWindowController(window: window))
    defer {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.orderOut(nil)
      document.close()
    }
    let url = root.appendingPathComponent("ValidationSheet.ldtxworkspace")
    try await save(document, to: url)
    document.storeService.preferences.landscapeProgramPreferences[99] = .init()
    document.storeService.preferences.portraitProgramPreferences[100] = .init()
    window.orderFront(nil)
    document.save(nil)
    for _ in 0..<100 where window.attachedSheet == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    let sheet = try #require(window.attachedSheet)
    func text(in view: NSView) -> [String] {
      (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
    }
    let messages = text(in: try #require(sheet.contentView)).joined(separator: "\n")
    #expect(messages.contains("Landscape"))
    #expect(messages.contains("Portrait"))
    #expect(messages.contains("99"))
    #expect(messages.contains("100"))
    window.endSheet(sheet)
    await Task.yield()
  }

  @Test func backgroundSnapshotValidationPrecedesIO() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    let url = root.appendingPathComponent("Invalid.ldtxworkspace")
    document.storeService.preferences.audioChannelGainsDecibels[99] = .with {
      $0.numerator = 0
      $0.denominator = 1
    }
    #expect(
      document.canAsynchronouslyWrite(
        to: url, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation))
    document.storeService.preferences.audioChannelGainsDecibels.removeValue(forKey: 99)
    let writer = BackgroundSnapshotWriter(document: document, destination: url)
    do {
      try await Task.detached { try writer.write() }.value
      Issue.record("Expected snapshot validation failure")
    } catch let error as WorkspaceSaveValidationError {
      #expect(error.messages.count == 1)
      #expect(error.failureReason?.contains("99") == true)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  private func validationProgram(name: String) -> Ldtx_Workspace_V4_ProgramDefinition {
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.displayName = name
    return program
  }

  private func validationPattern() -> Ldtx_Workspace_V4_VideoComponentWrapper {
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.testPattern.internalID = 2
    component.testPattern.displayName = "Pattern"
    return component
  }

  private func validationTransform(
    x: Ldtx_Workspace_V4_Rational32 = .with {
      $0.numerator = 0
      $0.denominator = 1
    },
    scale: Ldtx_Workspace_V4_Rational32 = .with {
      $0.numerator = 0
      $0.denominator = 1
    }
  )
    -> Ldtx_Workspace_V4_BasicTransform
  {
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationXRational = x
    transform.scaleXRational = scale
    return transform
  }

  @Test func monitorVolumeUsesAppletDataWithoutEditingDocument() throws {
    let suite = "MonitorVolume.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let document = WorkspaceDocument()
    defer { document.close() }
    let preferences = document.storeService.preferences
    let url = try #require(document.storeService.localStateURL)
    data.updateState(for: url) { $0.monitorVolume = -12.5 }
    #expect(data.state(for: url).monitorVolume == -12.5)
    #expect(document.storeService.preferences == preferences)
    #expect(!document.isDocumentEdited)
  }

  @Test func programSelectionUpdatesOwnedRuntimesAndStaysWindowLocal() async throws {
    let suite = "ProgramSelection.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let first = WorkspaceDocument()
    let second = WorkspaceDocument()
    defer {
      first.close()
      second.close()
    }
    first.storeService.definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    first.storeService.definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    let firstWindow = WorkspaceWindowController(
      storeService: first.storeService,
      persistenceCoordinator: first.persistenceCoordinator, appletData: data,
      documentReference: DocumentReference(first))
    first.addWindowController(firstWindow)
    let a = try firstWindow.windowRuntime.addProgram(displayName: "First")
    let b = try firstWindow.windowRuntime.addProgram(displayName: "Second")
    second.storeService.definition = first.storeService.definition
    let secondWindow = WorkspaceWindowController(
      storeService: second.storeService,
      persistenceCoordinator: second.persistenceCoordinator, appletData: data,
      documentReference: DocumentReference(second))
    second.addWindowController(secondWindow)
    try secondWindow.selectProgram(internalID: a)
    let landscape = try #require(firstWindow.windowRuntime.landscapeRuntime)
    let portrait = try #require(firstWindow.windowRuntime.portraitRuntime)
    let definition = first.storeService.definition
    first.storeService.inspectorSelector = .init(kind: .workspacePrograms)
    try firstWindow.selectProgram(internalID: b)
    #expect(firstWindow.windowRuntime.landscapeRuntime === landscape)
    #expect(firstWindow.windowRuntime.portraitRuntime === portrait)
    #expect(data.state(for: first.storeService.localStateURL!).selectedProgramInternalID == b)
    #expect(data.state(for: second.storeService.localStateURL!).selectedProgramInternalID == a)
    // Content is now the live AppKit controller connected to this document.
    #expect(
      (firstWindow.window as? WorkspaceWindow)?.contentPane.storeService.selectedProgram?
        .internalID == b)
    #expect(first.storeService.inspectorSelector == .init(kind: .workspacePrograms))
    let inspector = WorkspaceProgramsInspector(storeService: first.storeService, appletData: data)
    #expect(!inspector.canSelectProgram)
    #expect(inspector.programSelection.wrappedValue == a)
    #expect(second.storeService.inspectorSelector == nil)
    #expect(first.storeService.definition == definition)
    #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: UInt64.max) }
    for state: WorkspaceRecordingState in [.starting, .pausing, .stopping] {
      firstWindow.windowRuntime.setRecordingState(state)
      #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: a) }
      #expect(data.state(for: first.storeService.localStateURL!).selectedProgramInternalID == b)
    }
    firstWindow.windowRuntime.setRecordingState(.paused)
    try firstWindow.selectProgram(internalID: a)
    first.removeWindowController(firstWindow)
    #expect(firstWindow.document == nil)
    #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: b) }
    #expect(data.state(for: first.storeService.localStateURL!).selectedProgramInternalID == a)
    first.addWindowController(firstWindow)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Selection.ldtxworkspace")
    try await save(first, to: url)
    try firstWindow.selectProgram(internalID: b)
    await firstWindow.shutdown()
    first.close()
    let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    defer { reopened.close() }
    let reopenedWindow = WorkspaceWindowController(
      storeService: reopened.storeService,
      persistenceCoordinator: reopened.persistenceCoordinator, appletData: data,
      documentReference: DocumentReference(reopened))
    reopened.addWindowController(reopenedWindow)
    let reopenedInspector = WorkspaceProgramsInspector(
      storeService: reopened.storeService, appletData: data)
    #expect(data.state(for: url).selectedProgramInternalID == b)
    #expect(!reopenedInspector.canSelectProgram)
    #expect(reopenedInspector.programSelection.wrappedValue == a)
    #expect(
      (reopenedWindow.window as? WorkspaceWindow)?.contentPane.storeService.selectedProgram?
        .internalID == b)
    #expect(reopened.storeService.inspectorSelector == nil)
    await reopenedWindow.shutdown()
    await secondWindow.shutdown()
  }

  @Test func sharedAssignmentsUpdateBothWindowsAndStopObservingAfterShutdown() async throws {
    let suite = "WorkspaceDocumentAssignments.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let first = WorkspaceDocument()
    let second = WorkspaceDocument()
    defer {
      first.close()
      second.close()
    }
    first.storeService.definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    first.storeService.definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    let firstWindow = WorkspaceWindowController(
      storeService: first.storeService,
      persistenceCoordinator: first.persistenceCoordinator, appletData: data,
      documentReference: DocumentReference(first))
    first.addWindowController(firstWindow)
    let input = try firstWindow.windowRuntime.addVFXSource(displayName: "Camera")
    let program = try firstWindow.windowRuntime.addProgram(displayName: "Main")
    try firstWindow.windowRuntime.setVideoLayerOrder(
      [input], forProgramInternalID: program, target: .landscape)
    data.updateState(for: first.storeService.localStateURL!) {
      $0.selectedProgramInternalID = program
    }
    second.storeService.definition = first.storeService.definition
    let secondWindow = WorkspaceWindowController(
      storeService: second.storeService,
      persistenceCoordinator: second.persistenceCoordinator, appletData: data,
      documentReference: DocumentReference(second))
    second.addWindowController(secondWindow)
    data.updateState(for: second.storeService.localStateURL!) {
      $0.selectedProgramInternalID = program
    }
    let firstRuntime = try #require(firstWindow.windowRuntime.landscapeRuntime)
    let secondRuntime = try #require(secondWindow.windowRuntime.landscapeRuntime)
    data.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "test-camera"), for: input)
    for _ in 0..<100
    where firstRuntime.programState.read({ $0?.cameraIDsByInputKey["v4-\(input)"] })
      != "test-camera"
      || secondRuntime.programState.read({ $0?.cameraIDsByInputKey["v4-\(input)"] })
        != "test-camera"
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      firstRuntime.programState.read { $0?.cameraIDsByInputKey["v4-\(input)"] } == "test-camera")
    #expect(
      secondRuntime.programState.read { $0?.cameraIDsByInputKey["v4-\(input)"] } == "test-camera")
    first.presentedItemDidMove(
      to: URL(fileURLWithPath: "/tmp/MovedAssignments-\(UUID()).ldtxworkspace"))
    try await Task.sleep(for: .milliseconds(20))
    #expect(
      try firstWindow.windowRuntime.runtimeProjection(
        programInternalID: program, target: .landscape
      )
      .configuration.cameraIDsByInputKey["v4-\(input)"] == "test-camera")
    await firstWindow.shutdown()
    data.setPhysicalDeviceID(nil, for: input)
    for _ in 0..<100
    where secondRuntime.programState.read({ $0?.cameraIDsByInputKey.isEmpty }) != true {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      firstRuntime.programState.read { $0?.cameraIDsByInputKey["v4-\(input)"] } == "test-camera")
    #expect(secondRuntime.programState.read { $0?.cameraIDsByInputKey.isEmpty } == true)
    await secondWindow.shutdown()
  }

  @Test func standardControllerReusesDocumentWithoutAnExclusiveLock() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    let original = WorkspaceDocument()
    try await save(original, to: url)
    original.close()
    let controller = Self.controller
    let document = try #require(
      controller.makeDocument(withContentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
        as? WorkspaceDocument)
    controller.addDocument(document)
    defer { document.close() }
    #expect(document.fileURL == url)
    #expect(document.storeService.localStateURL == url)
    #expect(document.persistenceCoordinator.url == url)
    let independentlyOpened = try WorkspaceDocument(
      contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    independentlyOpened.close()
    let reopened: NSDocument = try await withCheckedThrowingContinuation { continuation in
      controller.openDocument(withContentsOf: url, display: false) { document, alreadyOpen, error in
        #expect(alreadyOpen)
        if let error {
          continuation.resume(throwing: error)
        } else if let document {
          continuation.resume(returning: document)
        } else {
          continuation.resume(throwing: CocoaError(.fileReadUnknown))
        }
      }
    }
    #expect(reopened === document)
    #expect(
      !FileManager.default.fileExists(
        atPath:
          root.appendingPathComponent(".Workspace.ldtxworkspace.LDTX.lock").path))
  }

  @Test func restorationUsesFormalPackageAndRejectsMissingOrNilURL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formal = root.appendingPathComponent("Formal.ldtxworkspace")
    let recovery = root.appendingPathComponent("LegacyRecovery.ldtxworkspace")
    let source = WorkspaceDocument()
    try await save(source, to: formal)
    source.close()
    var legacy = try WorkspaceBundleReaderV4(at: formal).read()
    legacy.definition.displayName = "Uncommitted legacy edit"
    try WorkspaceDocumentPackage.write(legacy, to: recovery, createsPackage: true)
    let document = try WorkspaceDocument(
      for: formal, withContentsOf: recovery,
      ofType: "tokyo.kaito.ldtx.workspace")
    defer { document.close() }
    #expect(document.fileURL == formal)
    #expect(document.storeService.definition.displayName == "Formal")
    #expect(!document.isDocumentEdited)
    #expect(document.autosavedContentsFileURL == nil)
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: nil, withContentsOf: recovery, ofType: "tokyo.kaito.ldtx.workspace")
    }
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: root.appendingPathComponent("Missing.ldtxworkspace"),
        withContentsOf: recovery, ofType: "tokyo.kaito.ldtx.workspace")
    }
    let corrupt = root.appendingPathComponent("Corrupt.ldtxworkspace")
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: corrupt, withContentsOf: recovery, ofType: "tokyo.kaito.ldtx.workspace")
    }
    #expect(
      try WorkspaceBundleReaderV4(at: recovery).read().definition.displayName
        == legacy.definition.displayName)
  }

  @Test func dockBadgeFollowsRegisteredDocuments() {
    let dockTile = NSApplication.shared.dockTile
    let originalBadge = dockTile.badgeLabel
    let controller = NSDocumentController.shared
    let first = WorkspaceDocument()
    let second = WorkspaceDocument()
    controller.addDocument(first)
    controller.addDocument(second)
    defer {
      first.close()
      second.close()
      dockTile.badgeLabel = originalBadge
    }
    first.storeService.isOutputActive = true
    first.storeService.isOutputActive = true
    second.storeService.isOutputActive = true
    #expect(dockTile.badgeLabel == "REC")
    first.storeService.isOutputActive = false
    #expect(dockTile.badgeLabel == "REC")
    second.storeService.isOutputActive = false
    #expect(dockTile.badgeLabel == nil)
    first.storeService.isOutputActive = true
    second.storeService.isOutputActive = true
    first.close()
    #expect(dockTile.badgeLabel == "REC")
    second.close()
    #expect(dockTile.badgeLabel == nil)
    #expect(!controller.documents.contains { $0 === first || $0 === second })
  }

  @Test func sidebarAdditionsStayInTheirDocumentAndPersistOnlyOnSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AddSheets-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Show.ldtxworkspace")
    let document = WorkspaceDocument()
    let other = WorkspaceDocument()
    defer {
      document.close()
      other.close()
    }
    try await save(document, to: url)
    let savedDefinition = document.storeService.definition
    let otherDefinition = other.storeService.definition
    var draft = WorkspaceAddDraft()
    draft.name = "Camera"
    draft.componentKind = .vfxSource
    let inputID = try WorkspaceResourceAddition.add(
      sheet: .videoComponent, draft: draft, devices: [], storeService: document.storeService)
    draft.name = "Color"
    draft.componentKind = .solidColor
    try WorkspaceResourceAddition.add(
      sheet: .videoComponent, draft: draft, devices: [], storeService: document.storeService)
    draft.name = "OCR"
    draft.videoComponentID = inputID
    try WorkspaceResourceAddition.add(
      sheet: .vision, draft: draft, devices: [], storeService: document.storeService)
    #expect(other.storeService.definition == otherDefinition)
    #expect(document.isDocumentEdited)
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition == savedDefinition)
    let expected = document.storeService.definition
    try await save(document, to: url, operation: .saveOperation)
    #expect(!document.isDocumentEdited)
    let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    defer { reopened.close() }
    #expect(reopened.storeService.definition == expected)
    #expect(
      reopened.storeService.definition.visions.first?.ocrVision.source
        == .videoComponentInternalID(inputID)
    )
  }

  private func save(
    _ document: WorkspaceDocument, to url: URL,
    operation: NSDocument.SaveOperationType = .saveAsOperation
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: url, ofType: "tokyo.kaito.ldtx.workspace", for: operation) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  @Test func newWorkspaceSaveCloseAndReopenRestoresPreview() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lifecycle-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Lifecycle.ldtxworkspace")
    let document = WorkspaceDocument()
    #expect(document.windowControllers.isEmpty)
    #expect(document.fileURL == nil)
    try await save(document, to: url)
    document.finishCreation(success: true)
    let initialWindow = try #require(document.windowControllers.first?.window as? WorkspaceWindow)
    #expect(initialWindow.isVisible)
    #expect(initialWindow.contentPane.storeService.selectedProgram == nil)
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 101
    program.displayName = "Main"
    program.landscapeVideoLayerInternalIds = [202, 203]
    program.portraitVideoLayerInternalIds = [202, 203]
    document.storeService.definition.programs = [program]
    document.storeService.definition.videoComponents = [
      WorkspaceResourceFactory.makeSolidColor(id: 202, name: "Color"),
      WorkspaceResourceFactory.makeClock(id: 203, name: "Clock"),
    ]
    document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
      .audioMasterVolumeDecibels = .with {
        $0.numerator = -8
        $0.denominator = 1
      }
    document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
      .videoLayerHidden[
        202] = true
    document.storeService.preferences.portraitProgramPreferences[101, default: .init()]
      .videoLayerHidden[
        203] = true
    document.storeService.inspectorSelector = .init(kind: .clockVideoComponent, internalID: 203)
    #expect(initialWindow.contentPane.storeService.selectedProgram != nil)
    #expect(document.isDocumentEdited)
    try await save(document, to: url, operation: .saveOperation)
    #expect(document.fileURL == url)
    #expect(document.storeService.localStateURL == url)
    #expect(!document.isDocumentEdited)
    let expectedDefinition = document.storeService.definition
    let expectedPreferences = document.storeService.preferences
    let firstController = try #require(
      document.windowControllers.first as? WorkspaceWindowController)
    await document.shutdown()
    document.close()
    #expect(!initialWindow.isVisible)
    let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    reopened.makeWindowControllers()
    reopened.showWindows()
    #expect(reopened.windowControllers.count == 1)
    let controller = try #require(reopened.windowControllers.first as? WorkspaceWindowController)
    let window = try #require(controller.window as? WorkspaceWindow)
    #expect(window !== initialWindow)
    #expect(window.isVisible)
    #expect(reopened.fileURL == url)
    #expect(reopened.storeService.localStateURL == url)
    #expect(reopened.storeService.inspectorSelector == nil)
    #expect(reopened.storeService.definition == expectedDefinition)
    #expect(reopened.storeService.preferences == expectedPreferences)
    #expect(!reopened.isDocumentEdited)
    #expect(window.contentPane.storeService.selectedProgram != nil)
    #expect(
      controller.pairedPreview.metalView.delegate === controller.previewRenderer)
    #expect(
      controller.previewRenderer !== firstController.previewRenderer
    )
    #expect(
      window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "workspace.toggleOutput" }
        == true)
    await reopened.shutdown()
    reopened.close()
  }

  @Test func newWorkspacePreservesInitialContentSize() async throws {
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
    #expect(contentSize.width >= 1062)
    #expect(contentSize.height >= 700)
    await document.shutdown()
    document.close()
  }

  @Test func ownsControllerAndUsesStandardRestoration() async throws {
    _ = NSApplication.shared
    let document = WorkspaceDocument()
    let controller = NSDocumentController.shared
    controller.addDocument(document)
    document.makeWindowControllers()
    let windowController = try #require(document.windowControllers.first)
    #expect(document.windowControllers.count == 1)
    #expect(windowController.document === document)
    let window = try #require(windowController.window)
    #expect(window.restorationClass as? NSDocumentController.Type != nil)
    document.makeWindowControllers()
    #expect(document.windowControllers.count == 1)
    await document.shutdown()
    document.close()
    #expect(!controller.documents.contains { $0 === document })
  }

  @Test func firstSaveNamesUntitledWorkspaceAndLaterSaveAsIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("Show.ldtxworkspace")
    try await save(document, to: first)
    #expect(document.storeService.definition.displayName == "Show")
    #expect(try WorkspaceBundleReaderV4(at: first).read().definition.displayName == "Show")
    #expect(!document.isDocumentEdited)
    let next = root.appendingPathComponent("Another.ldtxworkspace")
    do {
      try await save(document, to: next)
      Issue.record("Expected Save As rejection")
    } catch {}
    #expect(document.fileURL == first)
    #expect(!FileManager.default.fileExists(atPath: next.path))
    #expect(document.storeService.definition.displayName == "Show")
    document.close()
    let reopened = try WorkspaceDocument(contentsOf: first, ofType: "tokyo.kaito.ldtx.workspace")
    defer { reopened.close() }
    #expect(reopened.storeService.definition.displayName == "Show")
  }

  @Test func firstSavePreservesExplicitWorkspaceName() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    document.storeService.definition.displayName = "Custom"
    let destination = root.appendingPathComponent("Show.ldtxworkspace")
    try await save(document, to: destination)
    #expect(document.storeService.definition.displayName == "Custom")
    #expect(try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Custom")
  }

  @Test func tracksChangesSynchronouslyAndUsesAppKitSaveState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    let destination = root.appendingPathComponent("Saved.ldtxworkspace")
    #expect(document.fileURL == nil)
    document.storeService.definition.displayName = "Saved"
    #expect(document.isDocumentEdited)
    try await save(document, to: destination)
    #expect(!document.isDocumentEdited)
    #expect(document.fileURL == destination)
    #expect(document.persistenceCoordinator.url == destination)
    let saved = try WorkspaceBundleReaderV4(at: destination).read()
    #expect(saved.definitionExternalID?.split(separator: "-")[2].first == "7")
    #expect(saved.preferencesExternalID?.split(separator: "-")[2].first == "7")
    #expect(try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Saved")
    document.close()
    await Task.yield()
  }

  @Test func editsBeforeQueuedSaveStartsAreIncluded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Snapshot.ldtxworkspace")
    let document = WorkspaceDocument()
    document.storeService.definition.displayName = "Snapshot"
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation) {
        error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
      document.storeService.definition.displayName = "Later edit"
    }
    #expect(
      try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Later edit")
    #expect(document.storeService.definition.displayName == "Later edit")
    #expect(!document.isDocumentEdited)
    document.close()
  }

  @Test func backgroundSnapshotDoesNotIncludeLaterEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Snapshot.ldtxworkspace")
    let document = WorkspaceDocument()
    document.storeService.definition.displayName = "Snapshot"
    let token = document.changeCountToken(for: .saveOperation)
    #expect(
      document.canAsynchronouslyWrite(
        to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation))
    document.storeService.definition.displayName = "Later edit"
    let writer = BackgroundSnapshotWriter(document: document, destination: destination)
    try await Task.detached { try writer.write() }.value
    document.updateChangeCount(withToken: token, for: .saveOperation)
    #expect(
      try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Snapshot")
    #expect(document.isDocumentEdited)
    document.close()
  }

  @Test func autosaveOperationsAreDisabledAndRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 101
    program.displayName = "Main"
    document.storeService.definition.programs = [program]
    defer { document.close() }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    let definition = try Data(contentsOf: url.appendingPathComponent("definition.pb"))
    let preferences = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
    document.storeService.definition.displayName = "Pending"
    document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
      .audioMasterVolumeDecibels = .with {
        $0.numerator = -6
        $0.denominator = 1
      }
    #expect(!WorkspaceDocument.autosavesInPlace)
    #expect(!WorkspaceDocument.preservesVersions)
    #expect(document.autosavingFileType == nil)
    for operation in [
      NSDocument.SaveOperationType.autosaveInPlaceOperation,
      .autosaveElsewhereOperation, .autosaveAsOperation,
    ] {
      do {
        try await save(document, to: url, operation: operation)
        Issue.record("Autosaving must be rejected")
      } catch {}
    }
    try await document.autosave(withImplicitCancellability: false)
    #expect(try Data(contentsOf: url.appendingPathComponent("definition.pb")) == definition)
    #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == preferences)
    #expect(document.isDocumentEdited)
    #expect(document.autosavedContentsFileURL == nil)
  }

  @Test func creationShowsWindowsOnlyAfterSuccessfulSaveAndClosesFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    Self.controller.addDocument(document)
    #expect(document.windowControllers.isEmpty)
    let url = root.appendingPathComponent("New.ldtxworkspace")
    try await save(document, to: url)
    #expect(document.windowControllers.isEmpty)
    document.finishCreation(success: true)
    #expect(document.windowControllers.count == 1)
    #expect(document.windowControllers.first?.window?.isVisible == true)
    await document.shutdown()
    document.close()
    let canceled = WorkspaceDocument()
    Self.controller.addDocument(canceled)
    canceled.finishCreation(success: false)
    #expect(!Self.controller.documents.contains { $0 === canceled })
    let failed = WorkspaceDocument()
    Self.controller.addDocument(failed)
    let partial = root.appendingPathComponent("Partial.ldtxworkspace")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: partial.appendingPathComponent("preferences.pb"),
      withIntermediateDirectories: false)
    do {
      try await save(failed, to: partial)
      Issue.record("Expected first-save failure")
    } catch {}
    failed.finishCreation(success: false)
    #expect(!Self.controller.documents.contains { $0 === failed })
    #expect(
      FileManager.default.fileExists(atPath: partial.appendingPathComponent("Info.plist").path))
  }

  @Test func duplicateIsDisabledAndDoesNotCreateAnotherDocument() throws {
    let document = WorkspaceDocument()
    defer { document.close() }
    let documentsBefore = NSDocumentController.shared.documents
    #expect(
      !document.validateUserInterfaceItem(
        NSMenuItem(
          title: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "")))
    #expect(NSDocumentController.shared.documents.count == documentsBefore.count)
    #expect(document.fileURL == nil)
  }

  @Test func copyActionsAreDisabledAndSaveFailureKeepsEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 101
    program.displayName = "Main"
    document.storeService.definition.programs = [program]
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 102
    audio.displayName = "Input"
    document.storeService.definition.audioDevices = [audio]
    defer { document.close() }
    for action in [
      #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
      #selector(NSDocument.duplicate(_:)),
    ] {
      #expect(
        !document.validateUserInterfaceItem(
          NSMenuItem(title: "", action: action, keyEquivalent: "")))
    }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    document.writeProbe.withLock { $0 = { throw CocoaError(.fileWriteNoPermission) } }
    defer { document.writeProbe.withLock { $0 = nil } }
    document.storeService.definition.displayName = "Pending"
    do {
      try await save(document, to: url, operation: .saveOperation)
      Issue.record("Expected partial save failure")
    } catch {}
    #expect(document.isDocumentEdited)
    #expect(document.storeService.definition.displayName == "Pending")
    document.writeProbe.withLock { $0 = nil }
    try await save(document, to: url, operation: .saveOperation)
    #expect(!document.isDocumentEdited)
    document.storeService.isOutputActive = true
    let fixedDefinition = document.storeService.definition
    document.storeService.definition.displayName = "Rejected during output"
    document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
      .audioMasterVolumeDecibels = .with {
        $0.numerator = -8
        $0.denominator = 1
      }
    #expect(document.storeService.setAudioChannelGain(-12, forAudioInputDeviceInternalID: 102))
    try await save(document, to: url, operation: .saveOperation)
    let savedOutput = try WorkspaceBundleReaderV4(at: url).read()
    #expect(
      savedOutput.preferences.landscapeProgramPreferences[101]?.audioMasterVolumeDecibels
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = -8
          $0.denominator = 1
        })
    #expect(
      savedOutput.preferences.audioChannelGainsDecibels[102]
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = -12
          $0.denominator = 1
        })
    #expect(savedOutput.definition == fixedDefinition)
    document.storeService.isOutputActive = false
  }

  @Test func outputAllowsOnlyLayerPermutationsAndPersistsLatestOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer {
      document.storeService.isOutputActive = false
      document.close()
    }
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 101
    program.displayName = "Main"
    program.landscapeVideoLayerInternalIds = [1, 2, 3]
    program.portraitVideoLayerInternalIds = [3, 2, 1]
    document.storeService.definition.programs = [program]
    document.storeService.definition.videoComponents = [1, 2, 3].map { id in
      var device = Ldtx_Workspace_V4_VfxSourceComponent()
      device.internalID = UInt64(id)
      device.displayName = "Camera \(id)"
      var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      wrapper.vfxSource = device
      return wrapper
    }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    document.storeService.isOutputActive = true
    document.storeService.definition.programs[0].landscapeVideoLayerInternalIds = [3, 1, 2]
    document.storeService.definition.programs[0].portraitVideoLayerInternalIds = [1, 3, 2]
    #expect(document.isDocumentEdited)
    let reordered = document.storeService.definition
    for rejected: [UInt64] in [[3, 1], [3, 1, 2, 4], [3, 1, 1]] {
      document.storeService.definition.programs[0].landscapeVideoLayerInternalIds = rejected
      #expect(document.storeService.definition == reordered)
    }
    var mixed = reordered
    mixed.programs[0].landscapeVideoLayerInternalIds = [2, 3, 1]
    mixed.displayName = "Forbidden"
    document.storeService.definition = mixed
    #expect(document.storeService.definition == reordered)
    document.storeService.definition.programs[0].landscapeVideoLayerInternalIds = [2, 3, 1]
    let latest = document.storeService.definition
    document.storeService.definition.programs.removeAll()
    #expect(document.storeService.definition == latest)
    try await save(document, to: url, operation: .saveOperation)
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition == latest)
    document.storeService.isOutputActive = false
    let reopened = WorkspaceDocument()
    defer { reopened.close() }
    try reopened.read(from: url, ofType: "tokyo.kaito.ldtx.workspace")
    #expect(reopened.storeService.definition == latest)
  }

  @Test func editsCanProceedWhileBackgroundSaveIsPaused() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    document.storeService.definition.displayName = "Snapshot"
    let gate = DispatchSemaphore(value: 0)
    let handle = BackgroundSnapshotWriter(document: document, destination: url)
    defer { document.writeProbe.withLock { $0 = nil } }
    document.writeProbe.withLock { probe in
      probe = {
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            handle.document.storeService.definition.displayName = "Later edit"
            gate.signal()
          }
        }
        // A bounded wait fails rather than hanging if interaction remains blocked.
        #expect(!Thread.isMainThread)
        #expect(gate.wait(timeout: .now() + 5) == .success)
      }
    }
    try await save(document, to: url, operation: .saveOperation)
    document.writeProbe.withLock { $0 = nil }
    #expect(document.storeService.definition.displayName == "Later edit")
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Snapshot")
    #expect(document.isDocumentEdited)
  }

  @Test func presentedMoveRebindsStateAndPreservesResources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    let original = root.appendingPathComponent("Original.ldtxworkspace")
    let moved = root.appendingPathComponent("Renamed.ldtxworkspace")
    try await save(document, to: original)
    let resource = Data("Preserved resource".utf8)
    try resource.write(to: original.appendingPathComponent("resource.bin"))
    try FileManager.default.moveItem(at: original, to: moved)
    document.presentedItemDidMove(to: moved)
    for _ in 0..<100 where document.storeService.localStateURL != moved {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(document.fileURL == moved)
    #expect(document.storeService.localStateURL == moved)
    #expect(document.persistenceCoordinator.url == moved)
    let other = try WorkspaceDocument(contentsOf: moved, ofType: "tokyo.kaito.ldtx.workspace")
    other.close()
    document.storeService.definition.displayName = "After move"
    try await save(document, to: moved, operation: .saveOperation)
    #expect(!document.isDocumentEdited)
    #expect(try Data(contentsOf: moved.appendingPathComponent("resource.bin")) == resource)
    #expect(try WorkspaceBundleReaderV4(at: moved).read().definition.displayName == "After move")
  }

  @Test func moveKeepsRuntimeURLInSync() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    let original = root.appendingPathComponent("Original.ldtxworkspace")
    let moved = root.appendingPathComponent("Moved.ldtxworkspace")
    try await save(document, to: original)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.move(to: moved) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    #expect(document.fileURL == moved)
    #expect(document.persistenceCoordinator.url == moved)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    document.close()
  }

  @Test func startingOutputDoesNotSavePendingModelEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Output.ldtxworkspace")
    let document = WorkspaceDocument()
    defer { document.close() }
    try await save(document, to: url)
    let definition = try Data(contentsOf: url.appendingPathComponent("definition.pb"))
    let preferences = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
    document.makeWindowControllers()
    let controller = try #require(document.windowControllers.first as? WorkspaceWindowController)
    document.storeService.definition.displayName = "Pending"
    // No Program/output is enabled, so this exercises the entry without media I/O.
    try await controller.startOutput()
    #expect(document.isDocumentEdited)
    #expect(document.storeService.definition.displayName == "Pending")
    #expect(try Data(contentsOf: url.appendingPathComponent("definition.pb")) == definition)
    #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == preferences)
    await document.shutdown()
  }

  @Test func standardCloseCancelKeepsEditsAndDiscardWaitsForShutdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Close.ldtxworkspace")
    let document = WorkspaceDocument()
    defer { document.close() }
    try await save(document, to: url)
    Self.controller.addDocument(document)
    document.makeWindowControllers()
    let window = try #require(document.windowControllers.first?.window)
    window.orderFront(nil)
    document.storeService.definition.displayName = "Pending"
    let probe = WorkspaceCloseProbe()
    document.canClose(
      withDelegate: probe,
      shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickCloseSheetButton("Cancel", in: window)
    for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.result == false)
    #expect(document.isDocumentEdited)
    #expect(window.isVisible)
    #expect(Self.controller.documents.contains { $0 === document })
    probe.result = nil
    document.canClose(
      withDelegate: probe,
      shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickCloseSheetButton("Don’t Save", in: window)
    for _ in 0..<200 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.result == true)
    document.close()
    #expect(!Self.controller.documents.contains { $0 === document })
    #expect(!window.isVisible)
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Close")
  }

  private func clickCloseSheetButton(_ title: String, in window: NSWindow) async throws {
    func find(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton {
        let normalized = button.title.replacingOccurrences(of: "’", with: "'")
        let expected = title.replacingOccurrences(of: "’", with: "'")
        let japanese = ["Cancel": "キャンセル", "Don’t Save": "保存しない"][title]
        if normalized == expected || button.title == japanese { return button }
      }
      return view.subviews.lazy.compactMap { find($0) }.first
    }
    for _ in 0..<200 {
      if let content = window.attachedSheet?.contentView, let button = find(content) {
        button.performClick(nil)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.userCancelled)
  }

  @Test func outputFreezesDefinitionButTracksPreferences() {
    let document = WorkspaceDocument()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 101
    program.displayName = "Main"
    document.storeService.definition.programs = [program]
    document.updateChangeCount(.changeCleared)
    let original = document.storeService.definition
    document.storeService.isOutputActive = true
    document.storeService.definition.displayName = "Rejected"
    #expect(document.storeService.definition == original)
    #expect(!document.isDocumentEdited)
    document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
      .audioMasterVolumeDecibels = .with {
        $0.numerator = -6
        $0.denominator = 1
      }
    #expect(document.isDocumentEdited)
  }

  @Test func outputDisablesSaveAsAndRevert() {
    let document = WorkspaceDocument()
    document.storeService.isOutputActive = true
    let saveAs = NSMenuItem(
      title: "Save As", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "")
    let revert = NSMenuItem(
      title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
    #expect(!document.validateUserInterfaceItem(saveAs))
    #expect(!document.validateUserInterfaceItem(revert))
  }
}

// This handle exposes only the document's nonisolated, snapshot-based writer.
private struct BackgroundSnapshotWriter: @unchecked Sendable {
  let document: WorkspaceDocument
  let destination: URL
  func write() throws {
    try document.writeSafely(
      to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation)
  }
}

@MainActor
private final class WorkspaceCloseProbe: NSObject {
  var result: Bool?
  @objc func document(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    result = shouldClose
  }
}
