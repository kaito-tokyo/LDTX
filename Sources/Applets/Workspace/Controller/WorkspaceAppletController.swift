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
import LDTXWorkspaceAppletData
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import LDTXYouTubeRTMPS
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension NSCoder {
  fileprivate func decodeWorkspaceURL() -> URL? {
    return decodeObject(
      of: NSURL.self, forKey: "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.url") as URL?
  }

  fileprivate func encodeWorkspaceURL(_ url: URL?) {
    encode(url as NSURL?, forKey: "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.url")
  }
}

public enum WorkspaceAppletControllerError: Error {
  case invalidAppDelegateError
}

@MainActor
public final class WorkspaceAppletController: NSWindowController, NSWindowDelegate,
  NSWindowRestoration
{
  private static let deviceMappingAppletData = WorkspaceDeviceAppletData()

  private let workspaceReader: WorkspaceBundleReaderV4
  private let workspaceUIState: WorkspaceUIState
  private let workspaceDispatcher: WorkspaceDispatcher
  private let workspaceWindow: WorkspaceWindow


  let windowRuntime: WorkspaceWindowRuntime
  let recordingSession: WorkspaceV4RecordingSession
  let audioCoordinator: WorkspaceAudioCoordinator
  let visionFeature: WorkspaceV4VisionFeature
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private var workspaceObservationTask: Task<Void, Never>?
  private weak var recordingActivityReporter: (any WorkspaceRecordingActivityReporting)?
  private let workspaceID = UUID()
  private var hasReportedRecordingActivity = false

  public init(reader: WorkspaceBundleReaderV4) throws {
    self.workspaceReader = reader

    let workspace = try reader.read()
    self.workspaceUIState = WorkspaceUIState(
      definition: workspace.definition, preferences: workspace.preferences)
    
    self.workspaceDispatcher = WorkspaceDispatcher()
    
    self.workspaceWindow = WorkspaceWindow()
    
    super.init(window: workspaceWindow)
    
    workspaceDispatcher.workspaceAppletController = self

    let persistenceCoordinator = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: workspaceSnapshot,
      workspaceIsDirty: { uiState.isDirty },
      replaceWorkspace: { workspace in
        guard
          uiState.definition != workspace.definition
            || uiState.preferences != workspace.preferences
        else { return }
        uiState.definition = workspace.definition
        uiState.preferences = workspace.preferences
      },
      markWorkspaceSaved: {
        uiState.isDirty = false
      },
      deviceMappingAppletData: Self.deviceMappingAppletData)
    try persistenceCoordinator.open(workspace, at: url)

    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = WorkspaceWindowRuntime(
      persistence: persistenceCoordinator,
      captureSessionCoordinator: captureSessionCoordinator)

    let recordingSession = WorkspaceV4RecordingSession(windowRuntime: windowRuntime)
    let audioCoordinator = WorkspaceAudioCoordinator(
      captureSessionCoordinator: captureSessionCoordinator)
    let visionFeature = WorkspaceV4VisionFeature()
    let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory = {
      device, textureCache in
      BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
    }
    let programRuntimeFactory:
      @MainActor (
        WorkspaceCaptureSessionCoordinator, ProgramPreferencesState, LowFrequencyUpdateRegistry
      ) -> ProgramRuntime = { coordinator, preferences, registry in
        ProgramRuntime(
          captureSessionCoordinator: coordinator,
          backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
          programPreferencesState: preferences,
          lowFrequencyUpdateRegistry: registry)
      }
    windowRuntime.installRuntime(
      programRuntimeFactory(
        captureSessionCoordinator, ProgramPreferencesState(), lowFrequencyUpdateRegistry),
      role: .landscape)
    windowRuntime.installRuntime(
      programRuntimeFactory(
        captureSessionCoordinator, ProgramPreferencesState(), lowFrequencyUpdateRegistry),
      role: .portrait)
    windowRuntime.updateRuntimes()

    let window = makeWorkspaceWindow(
      url: url, sidebar: sidebar, content: content, inspector: inspector)
    self.workspaceWindow = window
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    super.init(window: window)

    workspaceDispatcher.set(workspaceAppletController: self)
    sidebar.rootView = AnyView(sidebarView.environment(\.workspaceDispatcher, workspaceDispatcher))
    content.rootView = AnyView(contentView.environment(\.workspaceDispatcher, workspaceDispatcher))
    inspector.rootView = AnyView(
      inspectorView.environment(\.workspaceDispatcher, workspaceDispatcher))

    guard let appDelegate = NSApplication.shared.delegate as? AppDelegateForWorkspaceApplet else {
      windowRuntime.shutdown()
      throw WorkspaceAppletControllerError.invalidAppDelegateError
    }
    appDelegate.retain(workspaceAppletController: self)

    let workspaceChanges = Observations { (uiState.definition, uiState.preferences) }
    self.workspaceObservationTask = Task { @MainActor [weak windowRuntime] in
      var previousDefinition = uiState.definition
      var previousPreferences = uiState.preferences
      for await (definition, preferences) in workspaceChanges {
        guard !Task.isCancelled, let windowRuntime else { return }
        guard definition != previousDefinition || preferences != previousPreferences else {
          continue
        }
        previousDefinition = definition
        previousPreferences = preferences
        workspaceDidChange()
        windowRuntime.updateRuntimes()
      }
    }

    window.delegate = self
    window.identifier = NSUserInterfaceItemIdentifier(
      "WorkspaceV4.AppKit.v1." + UUID().uuidString)
    window.restorationClass = Self.self
    window.isRestorable = true
    window.setFrameAutosaveName("WorkspaceV4.AppKit.v1")

    self.recordingActivityReporter =
      NSApplication.shared.delegate as? any WorkspaceRecordingActivityReporting
    recordingSession.stateDidChange = { [weak self] state in
      guard let self else { return }
      self.uiState.isOutputActive =
        switch state {
        case .starting, .recording, .stopping: true
        case .idle, .failed: false
        }
      self.reportRecordingActivity(for: state)
    }
    visionFeature.synchronize(
      visions: windowRuntime.definition.visions,
      context: windowRuntime.visionFeatureContext)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func saveWorkspaceDefinition() throws {
    try windowRuntime.saveWorkspaceDefinition()
    savedDefinition = uiState.definition
    workspaceDidChange()
  }

  func saveWorkspacePreferences() throws {
    try windowRuntime.saveWorkspacePreferences()
    savedPreferences = uiState.preferences
    workspaceDidChange()
  }

  private func workspaceDidChange() {
    uiState.isDirty =
      uiState.definition != savedDefinition
      || uiState.preferences != savedPreferences
  }
}

@MainActor
public final class WorkspaceWindow: NSWindow {
  private static let restorationKindKey = LDTXAppKitRestorationKeys.kind

  public let sidebarViewController: NSHostingController<WorkspaceSidebar>
  public let contentViewController: NSHostingController<WorkspaceContent>
  public let inspectorViewController: NSHostingController<WorkspaceInspectorContainer>
  
  public let splitViewController: NSSplitViewController

  init(
    url: URL, sidebar: NSViewController, content: NSViewController, inspector: NSViewController,
    uiState: WorkspaceUIState
  ) {
    let sidebarView = WorkspaceSidebar(uiState: uiState)
    sidebarView.sizingOptions = [.minSize]
    self.sidebarViewController = NSHostingController(rootView: sidebarView)
    
    let contentView = WorkspaceContent(
      windowRuntime: windowRuntime,
      recordingSession: recordingSession,
      deviceMappingAppletData: Self.deviceMappingAppletData,
      synchronizeVision: {
        visionFeature.synchronize(
          visions: windowRuntime.definition.visions,
          context: windowRuntime.visionFeatureContext)
      },
      synchronizeAudioMonitor: {
        Self.synchronizeAudioMonitor(
          windowRuntime: windowRuntime, audioCoordinator: audioCoordinator)
      })
    self.contentViewController = NSHostingController(rootView: sidebarView)
    
    let inspectorView = Form {
      WorkspaceInspectorContainer(
        windowRuntime: windowRuntime,
        recordingSession: recordingSession,
        uiState: uiState,
        deviceMappingAppletData: Self.deviceMappingAppletData)
    }
      .formStyle(.grouped)
      .padding(16)
      .accessibilityIdentifier("workspaceInspector")
    inspectorView.sizingOptions = [.minSize]
    self.inspectorViewController = NSHostingController(rootView: inspectorView)
    
    self.splitViewController = NSSplitViewController(nibName: nil, bundle: nil)
    
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.automaticallyAdjustsSafeAreaInsets = false
    splitViewController.addSplitViewItem(sidebarItem)

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    self.representedURL = url
    self.title = url.deletingPathExtension().lastPathComponent
    self.isReleasedWhenClosed = false
    self.contentViewController = splitViewController
    self.center()
  }

  public override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    coder.encodeWorkspaceURL(representedURL)
    coder.encode("workspace" as NSString, forKey: Self.restorationKindKey)
  }
}

extension WorkspaceAppletController {
  public func windowWillClose(_ notification: Notification) {
    (NSApplication.shared.delegate as? any AppDelegateForWorkspaceApplet)?
      .release(workspaceAppletController: self)
    workspaceObservationTask?.cancel()
    workspaceObservationTask = nil
    visionFeature.stop()
    Task {
      await recordingSession.stop()
      await withCheckedContinuation { continuation in
        windowRuntime.captureSessionCoordinator.stopAndReset {
          continuation.resume()
        }
      }
      await audioCoordinator.stopAndReset()
      lowFrequencyUpdateRegistry.shutdown()
      windowRuntime.shutdown()
    }
  }

  public func windowShouldClose(_ sender: NSWindow) -> Bool { true }

  // MARK: - NSWindowRestration

  public enum RestorationError: Error {
    case nilRestrationURLError
    case fileNotExistsError(URL)
  }

  public static func findWorkspaceWindow(for url: URL) -> WorkspaceWindow? {
    for window in NSApplication.shared.windows {
      guard let workspaceWindow = window as? WorkspaceWindow,
        let representedURL = workspaceWindow.representedURL,
        identifiesSamePackage(url, representedURL)
      else { continue }
      return workspaceWindow
    }

    return nil
  }

  private static func identifiesSamePackage(_ lhs: URL, _ rhs: URL) -> Bool {
    func resourceIdentifier(_ url: URL) -> NSObject? {
      guard
        let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
          .fileResourceIdentifier
      else { return nil }
      return identifier as? NSObject
    }

    guard let lhsIdentifier = resourceIdentifier(lhs),
      let rhsIdentifier = resourceIdentifier(rhs)
    else { return false }
    return lhsIdentifier.isEqual(rhsIdentifier)
  }

  public static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder
  ) async throws -> NSWindow {
    guard let decodedURL = state.decodeWorkspaceURL() else {
      throw RestorationError.nilRestrationURLError
    }
    let url = decodedURL.standardizedFileURL
    if let workspaceWindow = findWorkspaceWindow(for: url) {
      workspaceWindow.identifier = identifier
      return workspaceWindow
    } else {
      let reader: WorkspaceBundleReaderV4
      switch makeWorkspaceBundleReader(at: url) {
      case .v4(let v4Reader):
        reader = v4Reader
      case .failure:
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
      }
      let controller = try WorkspaceAppletController(reader: reader)
      controller.workspaceWindow.identifier = identifier
      return controller.workspaceWindow
    }
  }

  private func reportRecordingActivity(for state: WorkspaceV4RecordingSession.State) {
    guard let recordingActivityReporter else { return }
    let isRecording: Bool
    switch state {
    case .starting, .recording, .stopping: isRecording = true
    case .idle, .failed: isRecording = false
    }
    guard isRecording != hasReportedRecordingActivity else { return }
    hasReportedRecordingActivity = isRecording
    if isRecording {
      recordingActivityReporter.workspaceRecordingDidStart(workspaceID: workspaceID)
    } else {
      recordingActivityReporter.workspaceRecordingDidStop(workspaceID: workspaceID)
    }
  }

  private static func synchronizeAudioMonitor(
    windowRuntime: WorkspaceWindowRuntime,
    audioCoordinator: WorkspaceAudioCoordinator
  ) {
    guard let programInternalID = windowRuntime.selectedProgramInternalID,
      let projection = try? windowRuntime.runtimeProjection(
        programInternalID: programInternalID, role: .landscape)
    else {
      Task { await audioCoordinator.stopAndReset() }
      return
    }
    let audioDeviceIDs = Dictionary(
      uniqueKeysWithValues: windowRuntime.definition.inputDevices.compactMap {
        input -> (String, String)? in
        guard case .audioDevice(let device)? = input.definition,
          let physicalID = windowRuntime.physicalAudioDeviceID(for: device.internalID)
        else { return nil }
        return ("v4-\(device.internalID)", physicalID)
      })
    let monitoredKeys = Set(
      windowRuntime.definition.inputDevices.compactMap { input -> String? in
        guard case .audioDevice(let device)? = input.definition,
          windowRuntime.monitorsAudioInputDevice(device.internalID)
        else { return nil }
        return "v4-\(device.internalID)"
      })
    var preferences = projection.preferences
    preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
      fromDecibels: windowRuntime.preferences.monitorVolume)
    _ = audioCoordinator.restart(
      audioChannels: projection.configuration.audioChannels,
      inputAudioDeviceMappings: audioDeviceIDs,
      programPreferences: preferences,
      inputPassthroughChannelKeys: monitoredKeys,
      shouldRemainRunning: { true },
      failureHandler: { _ in },
      errorHandler: { _ in })
  }
}

@MainActor
func makeWorkspaceWindow(
  url: URL,
  sidebar: NSViewController,
  content: NSViewController,
  inspector: NSViewController
) -> WorkspaceWindow {
  WorkspaceWindow(url: url, sidebar: sidebar, content: content, inspector: inspector)
}
