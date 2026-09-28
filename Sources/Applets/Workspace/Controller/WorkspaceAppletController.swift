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
import SwiftUI
import UniformTypeIdentifiers

extension NSCoder {
  fileprivate func decodeWorkspaceURL() -> URL? {
    let key = "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.url"
    return decodeObject(of: NSURL.self, forKey: key) as URL?
  }

  fileprivate func encodeWorkspaceURL(_ url: URL?) {
    let key = "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.url"
    encode(url as NSURL?, forKey: key)
  }
}

@MainActor
public final class WorkspaceAppletController: NSWindowController, NSWindowDelegate,
  NSWindowRestoration
{
  private static let deviceMappingAppletData = WorkspaceDeviceAppletData()

  public let uiState: WorkspaceUIState
  public let workspaceWindow: WorkspaceWindow

  let windowRuntime: WorkspaceWindowRuntime
  let recordingSession: WorkspaceV4RecordingSession
  let audioCoordinator: WorkspaceAudioCoordinator
  let visionFeature: WorkspaceV4VisionFeature
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private weak var recordingActivityReporter: (any WorkspaceRecordingActivityReporting)?
  private let workspaceID = UUID()
  private var hasReportedRecordingActivity = false

  public init(url: URL) throws {
    let uiState = WorkspaceUIState()
    self.uiState = uiState

    let url = url.standardizedFileURL
    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = try WorkspaceWindowRuntime(
      opening: url,
      captureSessionCoordinator: captureSessionCoordinator,
      deviceMappingAppletData: Self.deviceMappingAppletData)
    uiState.definition = windowRuntime.store.definition
    uiState.preferences = windowRuntime.store.preferences

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

    let sidebar = NSHostingController(
      rootView: WorkspaceSidebar(workspaceBundleStore: windowRuntime.store, uiState: uiState))
    sidebar.sizingOptions = [.minSize]
    let content = NSHostingController(
      rootView: WorkspaceV4Content(
        store: windowRuntime.store,
        windowRuntime: windowRuntime,
        recordingSession: recordingSession,
        deviceMappingAppletData: Self.deviceMappingAppletData,
        saveBeforeStartingOutput: {
          guard windowRuntime.url != nil else { return false }
          if windowRuntime.store.isDirty {
            try windowRuntime.save()
          }
          return !windowRuntime.store.isDirty
        },
        synchronizeVision: {
          visionFeature.synchronize(
            visions: windowRuntime.store.definition.visions,
            context: windowRuntime.visionFeatureContext)
        },
        synchronizeAudioMonitor: {
          Self.synchronizeAudioMonitor(
            windowRuntime: windowRuntime, audioCoordinator: audioCoordinator)
        }))
    content.sizingOptions = [.minSize]
    let inspector = NSHostingController(
      rootView: Form {
        WorkspaceInspectorContainer(
          store: windowRuntime.store,
          windowRuntime: windowRuntime,
          recordingSession: recordingSession,
          uiState: uiState,
          deviceMappingAppletData: Self.deviceMappingAppletData)
      }
      .formStyle(.grouped)
      .padding(16)
      .accessibilityIdentifier("workspaceInspector"))
    inspector.sizingOptions = [.minSize]

    let window = makeWorkspaceWindow(
      url: url, sidebar: sidebar, content: content, inspector: inspector)
    self.workspaceWindow = window
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    super.init(window: window)

    window.controllerOwner = self
    window.delegate = self
    window.identifier = NSUserInterfaceItemIdentifier(
      "WorkspaceV4.AppKit.v1." + UUID().uuidString)
    window.restorationClass = Self.self
    window.isRestorable = true
    window.setFrameAutosaveName("WorkspaceV4.AppKit.v1")

    self.recordingActivityReporter = NSApp.delegate as? any WorkspaceRecordingActivityReporting
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
      visions: windowRuntime.store.definition.visions,
      context: windowRuntime.visionFeatureContext)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

}

@MainActor
public final class WorkspaceWindow: NSWindow, NSToolbarDelegate {
  private static let restorationKindKey = LDTXAppKitRestorationKeys.kind

  public var controllerOwner: NSWindowController?
  private var splitViewControllerStorage: NSSplitViewController?
  private var inspectorSplitViewItem: NSSplitViewItem?
  public private(set) var isInspectorCollapsed = false
  public var splitViewController: NSSplitViewController { splitViewControllerStorage! }
  public private(set) var expandedSidebarWidth: CGFloat = 240
  public private(set) var expandedInspectorWidth: CGFloat = 340
  private var resizeObserver: NSObjectProtocol?
  private var keyObserver: NSObjectProtocol?
  private var didApplyInitialPaneLayout = false
  private var hasRestoredPaneState = false

  init(
    url: URL, sidebar: NSViewController, content: NSViewController, inspector: NSViewController
  ) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    self.representedURL = url
    self.title = url.deletingPathExtension().lastPathComponent
    self.toolbarStyle = .unified
    self.isReleasedWhenClosed = false

    let split = NSSplitViewController(nibName: nil, bundle: nil)
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.minimumThickness = 240
    sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
    let contentItem = NSSplitViewItem(viewController: content)
    contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.canCollapse = true
    inspectorItem.canCollapseFromWindowResize = false
    inspectorItem.minimumThickness = 340
    inspectorItem.maximumThickness = 480
    inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
    for item in [sidebarItem, contentItem, inspectorItem] {
      item.automaticallyAdjustsSafeAreaInsets = false
      split.addSplitViewItem(item)
    }
    inspectorSplitViewItem = inspectorItem
    splitViewControllerStorage = split
    contentViewController = split

    let toolbar = NSToolbar(identifier: "WorkspaceV4Toolbar.AppKit.v1")
    toolbar.delegate = self
    self.toolbar = toolbar
    center()
    restoreDefaultPaneWidths()

    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSSplitView.didResizeSubviewsNotification,
      object: split.splitView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.didApplyInitialPaneLayout {
          self.paneLayoutDidChange()
        } else {
          DispatchQueue.main.async {
            MainActor.assumeIsolated { self.applyInitialPaneLayoutIfNeeded() }
          }
        }
      }
    }
    keyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: self,
      queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.applyInitialPaneLayoutIfNeeded() }
      }
    }
  }

  isolated deinit {
    if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
  }

  public override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    encodeWorkspacePaneState(with: coder)
  }

  func encodeWorkspacePaneState(with coder: NSCoder) {
    coder.encodeWorkspaceURL(representedURL)
    coder.encode("workspace" as NSString, forKey: Self.restorationKindKey)
    coder.encode(Double(expandedSidebarWidth), forKey: LDTXAppKitRestorationKeys.sidebarWidth)
    coder.encode(
      Double(expandedSidebarWidth), forKey: LDTXAppKitRestorationKeys.legacySidebarWidth)
    coder.encode(Double(expandedInspectorWidth), forKey: LDTXAppKitRestorationKeys.inspectorWidth)
    coder.encode(
      Double(expandedInspectorWidth), forKey: LDTXAppKitRestorationKeys.legacyInspectorWidth)
    coder.encode(
      splitViewController.splitViewItems[0].isCollapsed,
      forKey: LDTXAppKitRestorationKeys.sidebarCollapsed)
    coder.encode(
      splitViewController.splitViewItems[0].isCollapsed,
      forKey: LDTXAppKitRestorationKeys.legacySidebarCollapsed)
    coder.encode(isInspectorCollapsed, forKey: LDTXAppKitRestorationKeys.inspectorCollapsed)
    coder.encode(isInspectorCollapsed, forKey: LDTXAppKitRestorationKeys.legacyInspectorCollapsed)
  }

  public override func restoreState(with coder: NSCoder) {
    super.restoreState(with: coder)
    restoreWorkspacePaneState(with: coder)
    constrainFrameToVisibleScreen()
  }

  func restoreWorkspacePaneState(with coder: NSCoder) {
    let sidebarWidth = Self.decodeDouble(
      coder,
      currentKey: LDTXAppKitRestorationKeys.sidebarWidth,
      legacyKey: LDTXAppKitRestorationKeys.legacySidebarWidth)
    let inspectorWidth = Self.decodeDouble(
      coder,
      currentKey: LDTXAppKitRestorationKeys.inspectorWidth,
      legacyKey: LDTXAppKitRestorationKeys.legacyInspectorWidth)
    let sidebarCollapsed = Self.decodeBool(
      coder,
      currentKey: LDTXAppKitRestorationKeys.sidebarCollapsed,
      legacyKey: LDTXAppKitRestorationKeys.legacySidebarCollapsed)
    let inspectorCollapsed = Self.decodeBool(
      coder,
      currentKey: LDTXAppKitRestorationKeys.inspectorCollapsed,
      legacyKey: LDTXAppKitRestorationKeys.legacyInspectorCollapsed)
    hasRestoredPaneState =
      sidebarWidth != nil || inspectorWidth != nil
      || coder.containsValue(forKey: LDTXAppKitRestorationKeys.sidebarCollapsed)
      || coder.containsValue(forKey: LDTXAppKitRestorationKeys.legacySidebarCollapsed)
      || coder.containsValue(forKey: LDTXAppKitRestorationKeys.inspectorCollapsed)
      || coder.containsValue(forKey: LDTXAppKitRestorationKeys.legacyInspectorCollapsed)
    splitViewController.splitViewItems[0].isCollapsed = sidebarCollapsed
    isInspectorCollapsed = inspectorCollapsed
    if isInspectorCollapsed, let inspectorSplitViewItem {
      splitViewController.removeSplitViewItem(inspectorSplitViewItem)
    }
    splitViewController.view.layoutSubtreeIfNeeded()
    if let sidebarWidth, sidebarWidth.isFinite, sidebarWidth > 0 {
      expandedSidebarWidth = CGFloat(sidebarWidth)
    }
    if let inspectorWidth, inspectorWidth.isFinite, inspectorWidth > 0 {
      expandedInspectorWidth = CGFloat(inspectorWidth)
    }
    restorePaneWidths()
  }

  @objc public func toggleSidebar(_ sender: Any?) {
    let item = splitViewController.splitViewItems[0]
    guard item.canCollapse else { return }
    if !item.isCollapsed { rememberPaneWidths() }
    item.isCollapsed.toggle()
    if !item.isCollapsed {
      splitViewController.view.layoutSubtreeIfNeeded()
      splitViewController.splitView.setPosition(expandedSidebarWidth, ofDividerAt: 0)
    }
    invalidateRestorableState()
  }

  @objc public func toggleInspector(_ sender: Any?) {
    guard let inspectorSplitViewItem else { return }
    if isInspectorCollapsed {
      splitViewController.addSplitViewItem(inspectorSplitViewItem)
      isInspectorCollapsed = false
      splitViewController.view.layoutSubtreeIfNeeded()
      splitViewController.splitView.setPosition(
        splitViewController.splitView.bounds.width - expandedInspectorWidth
          - splitViewController.splitView.dividerThickness,
        ofDividerAt: 1)
    } else {
      rememberPaneWidths()
      splitViewController.removeSplitViewItem(inspectorSplitViewItem)
      isInspectorCollapsed = true
    }
    invalidateRestorableState()
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.init("workspace.sidebar"), .flexibleSpace, .init("workspace.inspector")]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  public func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    switch itemIdentifier.rawValue {
    case "workspace.sidebar":
      item.label = "Sidebar"
      item.paletteLabel = "Sidebar"
      item.toolTip = "Show or hide the Sidebar"
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
      item.target = self
      item.action = #selector(toggleSidebar(_:))
    case "workspace.inspector":
      item.label = "Inspector"
      item.paletteLabel = "Inspector"
      item.toolTip = "Show or hide the Inspector"
      item.image = NSImage(
        systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
      item.target = self
      item.action = #selector(toggleInspector(_:))
    default:
      return nil
    }
    return item
  }

  private func restoreDefaultPaneWidths() {
    splitViewController.view.layoutSubtreeIfNeeded()
    let splitView = splitViewController.splitView
    splitView.setPosition(240, ofDividerAt: 0)
    splitView.setPosition(240 + 480 + splitView.dividerThickness, ofDividerAt: 1)
  }

  private func rememberPaneWidths() {
    let splitView = splitViewController.splitView
    guard splitView.arrangedSubviews.count == 3 else { return }
    let sidebarWidth = splitView.arrangedSubviews[0].frame.width
    let inspectorWidth = splitView.arrangedSubviews[2].frame.width
    if sidebarWidth > 0 { expandedSidebarWidth = sidebarWidth }
    if inspectorWidth > 0 { expandedInspectorWidth = inspectorWidth }
  }

  private func paneLayoutDidChange() {
    guard didApplyInitialPaneLayout else { return }
    rememberPaneWidths()
    invalidateRestorableState()
  }

  private func restorePaneWidths() {
    splitViewController.view.layoutSubtreeIfNeeded()
    let splitView = splitViewController.splitView
    if !splitViewController.splitViewItems[0].isCollapsed {
      splitView.setPosition(expandedSidebarWidth, ofDividerAt: 0)
    }

    if !isInspectorCollapsed && splitViewController.splitViewItems.count == 3 {
      splitView.setPosition(
        splitView.bounds.width - expandedInspectorWidth - splitView.dividerThickness,
        ofDividerAt: 1)
    }
  }

  private func applyInitialPaneLayoutIfNeeded() {
    guard !didApplyInitialPaneLayout else { return }
    didApplyInitialPaneLayout = true
    splitViewController.view.layoutSubtreeIfNeeded()
    if hasRestoredPaneState {
      restorePaneWidths()
    } else {
      restoreDefaultPaneWidths()
    }
    rememberPaneWidths()
  }

  private func constrainFrameToVisibleScreen() {
    guard let screen = screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    var nextFrame = frame
    nextFrame.size.width = min(nextFrame.width, visible.width)
    nextFrame.size.height = min(nextFrame.height, visible.height)
    nextFrame.origin.x = min(max(nextFrame.minX, visible.minX), visible.maxX - nextFrame.width)
    nextFrame.origin.y = min(max(nextFrame.minY, visible.minY), visible.maxY - nextFrame.height)
    setFrame(nextFrame, display: false)
  }

  private static func decodeDouble(
    _ coder: NSCoder, currentKey: String, legacyKey: String
  ) -> Double? {
    if coder.containsValue(forKey: currentKey) { return coder.decodeDouble(forKey: currentKey) }
    if coder.containsValue(forKey: legacyKey) { return coder.decodeDouble(forKey: legacyKey) }
    return nil
  }

  private static func decodeBool(_ coder: NSCoder, currentKey: String, legacyKey: String) -> Bool {
    coder.decodeBool(forKey: coder.containsValue(forKey: currentKey) ? currentKey : legacyKey)
  }
}

extension WorkspaceAppletController {
  public func windowWillClose(_ notification: Notification) {
    workspaceWindow.controllerOwner = nil
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
    guard let url = state.decodeWorkspaceURL() else {
      throw RestorationError.nilRestrationURLError
    }
    switch makeWorkspaceBundleReader(at: url) {
    case .v4:
      break
    case .failure:
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }

    if let workspaceWindow = findWorkspaceWindow(for: url) {
      workspaceWindow.identifier = identifier
      return workspaceWindow
    } else {
      let controller = try WorkspaceAppletController(url: url)
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
          windowRuntime.store.monitorsAudioInputDevice(device.internalID)
        else { return nil }
        return "v4-\(device.internalID)"
      })
    var preferences = projection.preferences
    preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
      fromDecibels: windowRuntime.store.preferences.monitorVolume)
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
