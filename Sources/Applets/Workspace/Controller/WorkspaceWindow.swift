// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXCapture
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Observation
import QuickLookThumbnailing
import SwiftUI

public final class WorkspaceWindow: NSWindow {
  private weak var document: NSDocument?
  let appletData: WorkspaceAppletData
  let storeService: WorkspaceStoreService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private let reportError: (Error) -> Void
  private let editingState: WorkspaceEditingState
  let deviceRegistry: DeviceRegistryService

  let splitViewController: NSSplitViewController
  let contentPane: WorkspaceContentPane

  let screenshotResultPopover = NSPopover()
  private var inspectorCollapseObservation: NSKeyValueObservation?
  private var sidebarCollapseObservation: NSKeyValueObservation?
  private let toolbarCoordinator: WorkspaceToolbarCoordinator
  private var inferenceTask: Task<Void, Never>?
  private var isClosed = false
  let pendingEditsPopover = NSPopover()
  private var expandedSidebarWidth: CGFloat = 240

  var inspectorSplitViewItem: NSSplitViewItem? {
    splitViewController.splitViewItems[2]
  }

  init(
    document: NSDocument,
    appletData: WorkspaceAppletData,
    storeService: WorkspaceStoreService,
    editingState: WorkspaceEditingState,
    peakMeter: ProgramAudioPeakMeter,
    reportError: @escaping (Error) -> Void,
    deviceRegistry: DeviceRegistryService,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.document = document
    self.appletData = appletData
    self.storeService = storeService
    self.runtimeActions = runtimeActions
    self.reportError = reportError
    self.editingState = editingState
    self.deviceRegistry = deviceRegistry

    self.splitViewController = NSSplitViewController()
    self.contentPane = WorkspaceContentPane(
      storeService: storeService, appletData: appletData, editingState: editingState,
      peakMeter: peakMeter, reportError: reportError, pairedPreview: pairedPreview,
      runtimeActions: runtimeActions)

    toolbarCoordinator = WorkspaceToolbarCoordinator()
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)

    self.representedURL = document.fileURL
    self.title = document.fileURL?.lastPathComponent ?? "(Untitled)"
    self.isReleasedWhenClosed = false

    let sidebarController = NSHostingController(rootView: sidebarView)
    sidebarController.sizingOptions = [.minSize]
    sidebarController.sceneBridgingOptions = []

    let inspectorController = NSHostingController(rootView: inspectorView)
    inspectorController.sizingOptions = [.minSize]
    inspectorController.sceneBridgingOptions = []

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.holdingPriority = .init(260)
    let contentItem = NSSplitViewItem(viewController: contentPane)
    contentItem.holdingPriority = .init(250)
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
    inspectorItem.canCollapse = true
    inspectorItem.canCollapseFromWindowResize = false
    inspectorItem.maximumThickness = 480
    inspectorItem.holdingPriority = .init(260)
    for item in [sidebarItem, contentItem, inspectorItem] {
      item.automaticallyAdjustsSafeAreaInsets = false
      splitViewController.addSplitViewItem(item)
    }

    self.contentViewController = splitViewController
    self.titleVisibility = .visible
    self.toolbarStyle = .unified
    configureToolbar()
    self.toolbar = toolbarCoordinator.toolbar
    refreshToolbarState()
    // Installing the content controller replaces the initial size with its fitting size.
    let toolbarHeight = frame.height - contentLayoutRect.height
    self.setFrame(
      NSRect(origin: frame.origin, size: NSSize(width: 1062, height: 700 + toolbarHeight)),
      display: false)

    splitViewController.view.layoutSubtreeIfNeeded()
    let splitView = splitViewController.splitView
    splitView.setPosition(240, ofDividerAt: 0)
    splitView.setPosition(240 + 480 + splitView.dividerThickness, ofDividerAt: 1)
    NotificationCenter.default.addObserver(
      self, selector: #selector(paneLayoutChanged(_:)),
      name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) {
      [weak self] item, _ in
      let isCollapsed = item.isCollapsed
      MainActor.assumeIsolated {
        guard let self else { return }
        if !isCollapsed {
          let width = self.expandedSidebarWidth
          self.splitViewController.view.layoutSubtreeIfNeeded()
          self.splitViewController.splitView.setPosition(width, ofDividerAt: 0)
        }
        self.invalidateRestorableState()
      }
    }
    contentPane.configureAfterEstablished()

    inspectorCollapseObservation = splitViewController.splitViewItems[2].observe(
      \.isCollapsed, options: [.initial, .new]
    ) { [weak self] item, _ in
      let isCollapsed = item.isCollapsed
      MainActor.assumeIsolated {
        guard let self else { return }
        self.storeService.isInspectorVisible = !isCollapsed
        self.invalidateRestorableState()
      }
    }

    editingState.inputValidationErrorHandler = { [weak self] error in
      self?.showPendingEditsPopover(message: error.localizedDescription)
    }
    observeToolbarState()
    self.center()
  }

  @objc private func paneLayoutChanged(_ notification: Notification) {
    let split = splitViewController.splitView
    guard split.arrangedSubviews.count == 3 else { return }
    if !splitViewController.splitViewItems[0].isCollapsed {
      let width = split.arrangedSubviews[0].frame.width
      if width > 0 { expandedSidebarWidth = width }
    }
    invalidateRestorableState()
  }

  private func configureToolbar() {
    toolbarCoordinator.sidebarItem.label = String(localized: "Toggle Sidebar")
    toolbarCoordinator.sidebarItem.image = NSImage(
      systemSymbolName: "sidebar.left", accessibilityDescription: nil)
    toolbarCoordinator.sidebarItem.target = splitViewController
    toolbarCoordinator.sidebarItem.action = #selector(NSSplitViewController.toggleSidebar(_:))
    toolbarCoordinator.sidebarItem.isNavigational = true
    toolbarCoordinator.sidebarItem.autovalidates = false

    toolbarCoordinator.stopOutputItem.label = String(localized: "Stop Output")
    toolbarCoordinator.stopOutputItem.image = NSImage(
      systemSymbolName: "stop.fill", accessibilityDescription: nil)
    toolbarCoordinator.stopOutputItem.target = self
    toolbarCoordinator.stopOutputItem.action = #selector(stopOutput)
    toolbarCoordinator.stopOutputItem.isNavigational = true

    let startOutputLabel = String(localized: "Start Output")
    toolbarCoordinator.startPauseOutputItem.possibleLabels = [
      startOutputLabel,
      String(localized: "Pause Output"),
    ]
    toolbarCoordinator.startPauseOutputItem.label = startOutputLabel
    toolbarCoordinator.startPauseOutputItem.image = NSImage(
      systemSymbolName: "play.fill", accessibilityDescription: nil)
    toolbarCoordinator.startPauseOutputItem.target = self
    toolbarCoordinator.startPauseOutputItem.action = #selector(toggleOutput)
    toolbarCoordinator.startPauseOutputItem.isNavigational = true

    toolbarCoordinator.captureScreenshotsItem.label = String(localized: "Capture Screenshot(s)")
    toolbarCoordinator.captureScreenshotsItem.image = NSImage(
      systemSymbolName: "camera", accessibilityDescription: nil)
    toolbarCoordinator.captureScreenshotsItem.target = self
    toolbarCoordinator.captureScreenshotsItem.action = #selector(captureScreenshots)
    toolbarCoordinator.captureScreenshotsItem.isNavigational = true

    toolbarCoordinator.runInferenceItem.label = String(localized: "Run Inference")
    toolbarCoordinator.runInferenceItem.image = NSImage(
      systemSymbolName: "sparkles", accessibilityDescription: nil)
    toolbarCoordinator.runInferenceItem.target = self
    toolbarCoordinator.runInferenceItem.action = #selector(runInference)

    toolbarCoordinator.toggleInspectorItem.label = String(localized: "Toggle Inspector")
    toolbarCoordinator.toggleInspectorItem.image = NSImage(
      systemSymbolName: "sidebar.right", accessibilityDescription: nil)
    toolbarCoordinator.toggleInspectorItem.target = splitViewController
    toolbarCoordinator.toggleInspectorItem.action = #selector(NSSplitViewController.toggleInspector(_:))
    toolbarCoordinator.toggleInspectorItem.autovalidates = false

    toolbarCoordinator.toolbar.autosavesConfiguration = false
    toolbarCoordinator.toolbar.allowsUserCustomization = false
    toolbarCoordinator.toolbar.displayMode = .iconOnly
    toolbarCoordinator.toolbar.delegate = toolbarCoordinator
  }

  private func refreshToolbarState() {
    if !editingState.hasUnconfirmedChanges { pendingEditsPopover.close() }
    toolbarCoordinator.startPauseOutputItem.label =
      storeService.recordingState == .recording
      ? String(localized: "Pause Output") : String(localized: "Start Output")

  }

  private var inferenceRequest: (vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, url: URL)?
  {
    guard storeService.inspectorSelector?.kind == .ldtxSceneDetectorVision,
      let id = storeService.inspectorSelector?.internalID,
      let vision = storeService.workspaceDefinition.visions.compactMap({
        wrapper -> Ldtx_Workspace_V4_LdtxSceneDetectorVision? in
        if case .ldtxSceneDetectorVision(let vision)? = wrapper.vision,
          vision.internalID == id
        {
          return vision
        }
        return nil
      }).first,
      storeService.workspaceDefinition.videoComponents.contains(where: {
        $0.internalID == vision.videoComponentInternalID && $0.canBeVisionInput
          && $0.renderingSize != nil
      })
    else { return nil }
    let savedURL =
      vision.modelFileName.isEmpty
      ? nil
      : storeService.localStateURL?
        .appendingPathComponent("VisionModels/\(id)/\(vision.modelFileName)")
    guard let url = storeService.modelURLs[id] ?? savedURL else { return nil }
    return (vision, url)
  }

  @objc func runInference() {
    guard inferenceTask == nil, let request = inferenceRequest,
      let actions = runtimeActions()
    else { return }
    let id = request.vision.internalID
    storeService.visionResults.removeValue(forKey: id)
    storeService.visionFailureMessages.removeValue(forKey: id)
    inferenceTask = Task { [weak self] in
      guard let self else { return }
      defer {
        inferenceTask = nil
        refreshToolbarState()
      }
      do {
        let result = try await actions.classify(vision: request.vision, modelURL: request.url)
        storeService.visionResults[id] = result
      } catch {
        storeService.visionFailureMessages[id] = error.localizedDescription
      }
    }

    refreshToolbarState()
  }

  private func observeToolbarState() {
    guard !isClosed else { return }
    withObservationTracking {
      refreshToolbarState()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeToolbarState() }
    }
  }

  private func showPendingEditsPopover(
    message: String = "Press Return to confirm pending changes before selecting another item."
  ) {
    guard !isClosed else { return }
    splitViewController.splitViewItems[2].isCollapsed = false
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !isClosed else { return }
      contentView?.superview?.layoutSubtreeIfNeeded()
      pendingEditsPopover.close()
      pendingEditsPopover.behavior = .transient
      let controller = NSHostingController(
        rootView: Text(message)
          .padding().frame(width: 280))
      controller.sizingOptions = .preferredContentSize
      pendingEditsPopover.contentViewController = controller
      toolbarCoordinator.showPendingEditsPopover(pendingEditsPopover)
    }
  }

  private var sidebarView: some View {
    WorkspaceSidebar(
      storeService: storeService, editingState: editingState, deviceRegistry: deviceRegistry,
      appletData: appletData, document: document,
      onSelectionBlocked: { [weak self] in self?.showPendingEditsPopover() },
      runtimeActions: runtimeActions
    )
    .environment(\.workspaceReportError, reportError)
  }

  private var inspectorView: some View {
    WorkspaceInspectorContainer(
      deviceRegistry: deviceRegistry,
      storeService: storeService, editingState: editingState,
      appletData: appletData, document: document, runtimeActions: runtimeActions
    )
    .environment(\.workspaceReportError, reportError)
  }

  @objc func captureScreenshots() {
    do {
      guard let runtimeActions = runtimeActions() else {
        throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
      }
      let files = try runtimeActions.captureScreenshots()
      let programFiles = files.filter { $0.programCanvas != nil }
      showScreenshotResult(
        title: "Screenshots saved",
        message: programFiles.isEmpty
          ? "No Program screenshots were available."
          : programFiles.count == 1
            ? "Saved 1 Program screenshot." : "Saved \(programFiles.count) Program screenshots.",
        screenshots: programFiles.filter { $0.programCanvas == .landscape })
    } catch {
      if !showScreenshotResult(
        title: "Screenshot could not be captured", message: error.localizedDescription)
      {
        reportError(error)
      }
    }
  }

  @discardableResult
  private func showScreenshotResult(
    title: String, message: String, screenshots: [WorkspaceScreenshot] = []
  ) -> Bool {
    screenshotResultPopover.behavior = .transient
    let controller = NSHostingController(
      rootView: ScreenshotResultView(title: title, message: message, screenshots: screenshots))
    controller.sizingOptions = .preferredContentSize
    screenshotResultPopover.contentViewController = controller
    screenshotResultPopover.contentViewController?.view.setAccessibilityLabel(
      "\(title). \(message)")
    toolbarCoordinator.showScreenshotResultPopover(screenshotResultPopover)
    return true
  }

  public override func close() {
    isClosed = true
    pendingEditsPopover.close()
    editingState.inputValidationErrorHandler = nil
    inspectorCollapseObservation?.invalidate()
    sidebarCollapseObservation?.invalidate()
    NotificationCenter.default.removeObserver(
      self, name: NSSplitView.didResizeSubviewsNotification,
      object: splitViewController.splitView)
    screenshotResultPopover.close()
    super.close()
  }

  @objc func stopOutput() {
    guard storeService.recordingState.canStop else { return }
    Task { await runtimeActions()?.stopOutput() }
  }

  @objc func toggleOutput() {
    let state = storeService.recordingState
    guard state.canStart || state == .recording else { return }
    Task {
      if state == .recording {
        await runtimeActions()?.pauseOutput()
      } else {
        do {
          try editingState.requireConfirmedEdits()
          guard let runtimeActions = runtimeActions() else {
            throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
          }
          try await runtimeActions.startOutput()
        } catch {
          storeService.outputFailureMessage = error.localizedDescription
        }
      }
    }
  }

}

extension WorkspaceWindow: NSToolbarItemValidation {
  public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    guard !isClosed,
      let identifier = WorkspaceToolbarCoordinator.Identifiers(rawValue: item.itemIdentifier.rawValue)
    else { return false }
    return switch identifier {
    case .captureScreenshots: true
    case .stopOutput: storeService.recordingState.canStop
    case .startPauseOutput:
      storeService.recordingState.canStart || storeService.recordingState == .recording
    case .runInference:
      inferenceTask == nil && inferenceRequest != nil && runtimeActions() != nil
    default: false
    }
  }
}

struct ScreenshotResultView: View {
  let title: String
  let message: String
  let screenshots: [WorkspaceScreenshot]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(message)
      ForEach(screenshots, id: \.url) { screenshot in
        Button {
          NSWorkspace.shared.open(screenshot.url)
        } label: {
          HStack(spacing: 10) {
            FileIcon(url: screenshot.url)
            Text(screenshot.url.lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(screenshot.url.path)
        .onDrag { NSItemProvider(object: screenshot.url as NSURL) }
      }
    }
    .padding()
    .frame(width: screenshots.isEmpty ? 280 : 360, alignment: .leading)
  }

  private struct FileIcon: View {
    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
      Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .scaledToFit()
        .frame(width: 32, height: 32)
        .task(id: url) {
          image = nil
          let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 32, height: 32), scale: displayScale,
            representationTypes: .all)
          request.iconMode = true
          guard
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
              for: request),
            !Task.isCancelled
          else { return }
          image = representation.nsImage
        }
    }
  }
}
