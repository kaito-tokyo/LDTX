// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppInterface
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import UniformTypeIdentifiers

/// The native window for a Version 4 Workspace.
@MainActor
public final class DefaultWorkspaceAppletController: NSWindowController,
  WorkspaceAppletController, NSWindowDelegate, NSToolbarDelegate, NSWindowRestoration
{
  public static let packagePathExtension = WorkspacePackageLayout.pathExtension

  public static func open(
    url: URL,
    recordingActivityReporter: (any WorkspaceRecordingActivityReporting)? = nil,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    let url = url.standardizedFileURL
    var existingController: DefaultWorkspaceAppletController?
    for window in NSApp.windows {
      guard let controller = window.windowController as? DefaultWorkspaceAppletController,
        let representedURL = window.representedURL,
        representedURL.standardizedFileURL == url,
        window.isVisible,
        !controller.isClosing
      else { continue }
      existingController = controller
      break
    }
    if let controller = existingController {
      if let recordingActivityReporter {
        controller.setRecordingActivityReporter(recordingActivityReporter)
      }
      completionHandler(controller.window, nil)
      return
    }
    let controller = DefaultWorkspaceAppletController(
      url: url,
      recordingActivityReporter: recordingActivityReporter)
    guard controller.start() else {
      controller.close()
      completionHandler(nil, nil)
      return
    }
    completionHandler(controller.window, nil)
  }

  let session: WorkspaceV4SessionService
  let split: PaneSplitViewController
  private let recordingSession: WorkspaceV4RecordingSession
  public var isRecording: Bool { recordingSession.isRecording }
  let audioCoordinator: WorkspaceAudioCoordinator
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  let visionFeature: any WorkspaceV4VisionFeatureProviding
  private let workspaceID = UUID()
  private weak var recordingActivityReporter: (any WorkspaceRecordingActivityReporting)?
  private var hasReportedRecordingActivity = false
  public private(set) var url: URL
  private var isClosingAfterConfirmation = false
  public private(set) var isClosing = false

  public init(
    url: URL,
    recordingActivityReporter: (any WorkspaceRecordingActivityReporting)? = nil
  ) {
    self.url = url.standardizedFileURL
    lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()
    let store = try! WorkspaceV4Store(cleanNamed: "Untitled Workspace")
    let persistence = WorkspaceV4PersistenceCoordinator(store: store)
    let session = WorkspaceV4SessionService(
      persistence: persistence,
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
    self.session = session
    let recordingSession = WorkspaceV4RecordingSession(workspaceSession: session)
    self.recordingSession = recordingSession
    let audioCoordinator = WorkspaceAudioCoordinator(
      captureSessionCoordinator: session.captureSessionCoordinator)
    self.audioCoordinator = audioCoordinator
    visionFeature = WorkspaceV4VisionFeature()
    let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = {
      device, textureCache in
      BackgroundRemovalVideoInputPreprocessor(
        device: device,
        textureCache: textureCache
      )
    }
    let programRuntimeFactory:
      @MainActor (
        WorkspaceCaptureSessionCoordinator, ProgramPreferencesState, LowFrequencyUpdateRegistry
      ) -> ProgramRuntime = { coordinator, preferences, registry in
        ProgramRuntime(
          captureSessionCoordinator: coordinator,
          backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
          programPreferencesState: preferences,
          lowFrequencyUpdateRegistry: registry
        )
      }
    let split = WorkspaceWindowUIFactory.makeSplit(
      session: session,
      recordingSession: recordingSession,
      audioCoordinator: audioCoordinator,
      visionFeature: visionFeature)
    self.split = split
    let window = PaneWindow(contentViewController: split)
    window.title = "Workspace"
    window.titleVisibility = .hidden
    window.setContentSize(NSSize(width: 1062, height: 700))
    window.center()
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    super.init(window: window)
    self.recordingActivityReporter = recordingActivityReporter
    recordingSession.stateDidChange = { [weak self] state in
      self?.reportRecordingActivity(for: state)
    }
    window.windowControllerOwner = self
    window.delegate = self
    configureRestoration(for: window)
    let toolbar = NSToolbar(identifier: "WorkspaceV4Toolbar.AppKit.v1")
    toolbar.delegate = self
    window.toolbar = toolbar
    window.setFrameAutosaveName("WorkspaceV4.AppKit.v1")
    split.setInitialWidths(sidebar: 240, content: 480)
    session.installRuntime(
      programRuntimeFactory(
        session.captureSessionCoordinator,
        ProgramPreferencesState(),
        lowFrequencyUpdateRegistry),
      role: .landscape)
    session.installRuntime(
      programRuntimeFactory(
        session.captureSessionCoordinator,
        ProgramPreferencesState(),
        lowFrequencyUpdateRegistry),
      role: .portrait)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  @discardableResult
  public func start() -> Bool {
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try session.open(at: url)
      } else {
        try session.create(displayName: url.deletingPathExtension().lastPathComponent)
        try session.save(to: url)
      }
      visionFeature.synchronize(
        visions: session.definition.visions,
        context: session.visionFeatureContext
      )
      return true
    } catch {
      present(error: error)
      return false
    }
  }

  public func save() {
    guard let url = session.url else {
      saveAs()
      return
    }
    do { try session.save(to: url) } catch { present(error: error) }
  }

  public func saveAs() {
    guard !recordingSession.isRecording else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.workspace")]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try session.save(to: url)
      self.url = url.standardizedFileURL
      configureRestoration(for: window)
    } catch { present(error: error) }
  }

  public func reload() {
    guard !recordingSession.isRecording else { return }
    if session.isDirty {
      let alert = NSAlert()
      alert.messageText = "Discard unsaved changes and reload?"
      alert.informativeText = "The Workspace will be replaced with its saved state on disk."
      alert.addButton(withTitle: "Reload")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    do {
      try session.reloadFromDisk()
      let availableCameraIDs = Set(session.availableCaptureDevices().cameras.map(\.id))
      session.synchronizeCaptureInputs(availableCameraIDs: availableCameraIDs) { _ in }
      visionFeature.synchronize(
        visions: session.definition.visions,
        context: session.visionFeatureContext)
      synchronizeAudioMonitor()
    } catch { present(error: error) }
  }

  @objc public func toggleInspector(_ sender: Any?) {
    split.toggleInspector(sender)
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .init("inspector")]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  public func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard itemIdentifier.rawValue == "inspector" else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "Inspector"
    item.paletteLabel = "Inspector"
    item.toolTip = "Show or hide the Inspector"
    item.image = NSImage(
      systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")
    item.target = self
    item.action = #selector(toggleInspector(_:))
    return item
  }

  private func configureRestoration(for window: NSWindow?) {
    guard let window else { return }
    window.title = url.deletingPathExtension().lastPathComponent
    window.representedURL = url
    if let paneWindow = window as? PaneWindow {
      paneWindow.restorationURL = url
      paneWindow.restorationKind = "workspace"
    }
    window.restorationClass = DefaultWorkspaceAppletController.self
    window.isRestorable = true
    window.identifier =
      window.identifier
      ?? NSUserInterfaceItemIdentifier("WorkspaceV4.AppKit.v1." + UUID().uuidString)
    window.invalidateRestorableState()
  }

  public func closeWorkspace() async {
    visionFeature.stop()
    await recordingSession.stop()
    await withCheckedContinuation { continuation in
      session.captureSessionCoordinator.stopAndReset { continuation.resume() }
    }
    await audioCoordinator.stopAndReset()
    lowFrequencyUpdateRegistry.shutdown()
    session.close()
  }

  public func windowWillClose(_ notification: Notification) {
    isClosing = true
    visionFeature.stop()
    (window as? PaneWindow)?.windowControllerOwner = nil
    Task { await self.closeWorkspace() }
  }

  func confirmClose() -> Bool {
    confirmClose(stoppingOutput: false)
  }

  public func confirmTermination() -> Bool {
    confirmClose(stoppingOutput: true)
  }

  public func cancelTerminationConfirmation() {
    isClosingAfterConfirmation = false
  }

  private func confirmClose(stoppingOutput: Bool) -> Bool {
    guard stoppingOutput || !recordingSession.isRecording else {
      let alert = NSAlert()
      alert.messageText = "Stop output before closing this Workspace."
      alert.informativeText =
        "The active output session must be stopped before this Workspace can close."
      alert.runModal()
      return false
    }
    guard !isClosingAfterConfirmation, session.isDirty else { return true }

    let alert = NSAlert()
    alert.messageText = "Save changes to this Workspace?"
    alert.informativeText =
      "Your unsaved Workspace changes will be lost if you close without saving."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Discard")
    alert.alertStyle = .warning

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      save()
      guard !session.isDirty else { return false }
      isClosingAfterConfirmation = true
      return true
    case .alertThirdButtonReturn:
      isClosingAfterConfirmation = true
      return true
    default:
      return false
    }
  }

  public func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

  private func present(error: Error) {
    let alert = NSAlert(error: error)
    guard let window, window.isVisible else {
      alert.runModal()
      return
    }
    alert.beginSheetModal(for: window)
  }

  private func synchronizeAudioMonitor() {
    synchronizeV4AudioMonitor(session: session, audioCoordinator: audioCoordinator)
  }

  private func setRecordingActivityReporter(
    _ reporter: any WorkspaceRecordingActivityReporting
  ) {
    recordingActivityReporter = reporter
    reportRecordingActivity(for: recordingSession.state)
  }

  private func reportRecordingActivity(for state: WorkspaceV4RecordingSession.State) {
    guard let recordingActivityReporter else { return }
    let isRecording: Bool
    switch state {
    case .starting, .recording, .stopping:
      isRecording = true
    case .idle, .failed:
      isRecording = false
    }
    guard isRecording != hasReportedRecordingActivity else { return }
    hasReportedRecordingActivity = isRecording
    if isRecording {
      recordingActivityReporter.workspaceRecordingDidStart(workspaceID: workspaceID)
    } else {
      recordingActivityReporter.workspaceRecordingDidStop(workspaceID: workspaceID)
    }
  }

  public static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier,
    state: NSCoder,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    let url =
      (state.decodeObject(of: NSURL.self, forKey: LDTXAppKitRestorationKeys.url) as URL?)
      ?? (state.decodeObject(of: NSURL.self, forKey: LDTXAppKitRestorationKeys.legacyURL) as URL?)
    guard let url, FileManager.default.fileExists(atPath: url.path) else {
      completionHandler(nil, nil)
      return
    }
    DefaultWorkspaceAppletController.open(
      url: url,
      recordingActivityReporter: NSApp.delegate as? any WorkspaceRecordingActivityReporting
    ) { window, error in
      window?.identifier = identifier
      completionHandler(window, error)
    }
  }
}

@MainActor
private func synchronizeV4AudioMonitor(
  session: WorkspaceV4SessionService,
  audioCoordinator: WorkspaceAudioCoordinator
) {
  guard let programInternalID = session.selectedProgramInternalID,
    let projection = try? session.runtimeProjection(
      programInternalID: programInternalID, role: .landscape)
  else {
    Task { await audioCoordinator.stopAndReset() }
    return
  }
  let audioDeviceIDs = Dictionary(
    uniqueKeysWithValues:
      session.definition.inputDevices.compactMap {
        input -> (String, String)? in
        guard case .audioDevice(let device)? = input.definition,
          let physicalID = session.physicalAudioDeviceID(for: device.internalID)
        else { return nil }
        return ("v4-\(device.internalID)", physicalID)
      })
  let monitoredKeys = Set(
    session.definition.inputDevices.compactMap {
      input -> String? in
      guard case .audioDevice(let device)? = input.definition,
        session.monitorsAudioInputDevice(device.internalID)
      else { return nil }
      return "v4-\(device.internalID)"
    })
  var preferences = projection.preferences
  preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
    fromDecibels: session.preferences.monitorVolume)
  _ = audioCoordinator.restart(
    audioChannels: projection.configuration.audioChannels,
    inputAudioDeviceMappings: audioDeviceIDs,
    programPreferences: preferences,
    inputPassthroughChannelKeys: monitoredKeys,
    shouldRemainRunning: { true },
    failureHandler: { _ in },
    errorHandler: { _ in })
}
