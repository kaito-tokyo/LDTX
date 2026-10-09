// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXCapture
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Observation
import QuickLookThumbnailing
import SwiftUI

public final class WorkspaceWindow: NSWindow, NSToolbarDelegate {
  private weak var document: NSDocument?
  private let documentReference: DocumentReference
  let appletData: WorkspaceAppletData
  let storeService: WorkspaceStoreService
  let deviceRegistry: DeviceRegistryService

  let splitViewController: NSSplitViewController
  let contentPane: WorkspaceContentPane

  let screenshotResultPopover = NSPopover()
  private var inspectorCollapseObservation: NSKeyValueObservation?
  private var sidebarCollapseObservation: NSKeyValueObservation?
  private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
  private var isClosed = false
  let pendingEditsPopover = NSPopover()
  private var expandedSidebarWidth: CGFloat = 240
  private var expandedInspectorWidth: CGFloat = 340

  init(
    document: NSDocument,
    appletData: WorkspaceAppletData,
    storeService: WorkspaceStoreService,
    deviceRegistry: DeviceRegistryService,
    pairedPreview: ProgramCanvasPairedPreview
  ) {
    self.document = document
    self.documentReference = DocumentReference(document)
    self.appletData = appletData
    self.storeService = storeService
    self.deviceRegistry = deviceRegistry

    self.splitViewController = NSSplitViewController()
    self.contentPane = WorkspaceContentPane(
      storeService: storeService, pairedPreview: pairedPreview)

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
    let toolbar = NSToolbar(identifier: "workspace")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = false
    toolbar.displayMode = .iconOnly
    self.toolbar = toolbar
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
        self.toolbarItems[.init("workspace.inspector.apply")]?.isHidden = isCollapsed
        self.toolbarItems[.init("workspace.inspector.title")]?.isHidden = isCollapsed
        if !isCollapsed {
          let width = self.expandedInspectorWidth
          self.splitViewController.view.layoutSubtreeIfNeeded()
          let splitView = self.splitViewController.splitView
          splitView.setPosition(
            splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: 1)
        }
        self.invalidateRestorableState()
      }
    }

    storeService.pendingEditsDidBlockSelection = { [weak self] in
      self?.showPendingEditsPopover()
    }
    storeService.inputValidationErrorHandler = { [weak self] error in
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
    if !splitViewController.splitViewItems[2].isCollapsed {
      let width = split.arrangedSubviews[2].frame.width
      if width > 0 { expandedInspectorWidth = width }
    }
    invalidateRestorableState()
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      "workspace.sidebar", "workspace.stopOutput", "workspace.toggleOutput",
      "workspace.captureScreenshots", NSToolbarItem.Identifier.flexibleSpace.rawValue,
      NSToolbarItem.Identifier.inspectorTrackingSeparator.rawValue,
      "workspace.inspector.title", NSToolbarItem.Identifier.flexibleSpace.rawValue,
      "workspace.inspector.apply",
      "workspace.inspector",
    ].map { NSToolbarItem.Identifier($0) }
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  public func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if let item = toolbarItems[identifier] { return item }
    // AppKit supplies its standard space and tracking separator items.
    guard identifier != .flexibleSpace, identifier != .inspectorTrackingSeparator else {
      return nil
    }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.target = self
    item.autovalidates = false
    let label: String
    let symbol: String?
    switch identifier.rawValue {
    case "workspace.sidebar":
      label = "Sidebar"
      symbol = "sidebar.left"
      item.action = #selector(toggleSidebar)
    case "workspace.stopOutput":
      label = "Stop Output"
      symbol = "stop.fill"
      item.action = #selector(stopOutput)
    case "workspace.toggleOutput":
      label = "Start Output"
      symbol = "play.fill"
      item.action = #selector(toggleOutput)
    case "workspace.captureScreenshots":
      label = "Capture Screenshot(s)"
      symbol = "camera"
      item.action = #selector(captureScreenshots)
    case "workspace.inspector.title":
      label = inspectorTitle
      symbol = nil
      let titleView = NSTextField(labelWithString: label)
      titleView.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      titleView.lineBreakMode = .byTruncatingTail
      titleView.setAccessibilityLabel("Inspector title")
      item.view = titleView
      item.isHidden = !storeService.isInspectorVisible
    case "workspace.inspector":
      label = "Inspector"
      symbol = "sidebar.right"
      item.action = #selector(toggleInspector)
    case "workspace.inspector.apply":
      label = "Apply"
      symbol = nil
      item.action = #selector(applyPendingEdits)
      item.isHidden = !storeService.isInspectorVisible
    default: return nil
    }
    item.label = label
    if symbol == nil && item.view == nil {
      item.title = label
      item.isBordered = true
    }
    if let symbol {
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }
    toolbarItems[identifier] = item
    updateToolbarItems()
    return item
  }

  private func updateToolbarItems() {
    if !storeService.hasUnconfirmedChanges { pendingEditsPopover.close() }
    if let item = toolbarItems[.init("workspace.inspector.title")],
      let titleView = item.view as? NSTextField
    {
      item.label = inspectorTitle
      titleView.stringValue = inspectorTitle
      titleView.sizeToFit()
    }
    toolbarItems[.init("workspace.stopOutput")]?.isEnabled = storeService.recordingState.canStop
    if let item = toolbarItems[.init("workspace.toggleOutput")] {
      let recording = storeService.recordingState == .recording
      item.label = recording ? "Pause Output" : "Start Output"
      item.image = NSImage(
        systemSymbolName: recording ? "pause.fill" : "play.fill",
        accessibilityDescription: item.label)
      item.isEnabled = storeService.recordingState.canStart || recording
    }
    toolbarItems[.init("workspace.inspector.apply")]?.isEnabled =
      storeService.hasUnconfirmedChanges && !storeService.isOutputActive
      && !storeService.hasPendingSubmit
  }

  var inspectorTitle: String {
    guard let kind = storeService.inspectorSelector?.kind else { return "Inspector" }
    return switch kind {
    case .invalid: "Inspector"
    case .workspacePrograms: "Programs"
    case .workspaceCanvas: "Canvas"
    case .workspaceOutput: "Output"
    case .audioInputDevice: "Audio Input Device"
    case .vfxVideoComponent: "VFX Source"
    case .solidColorFillVideoComponent: "Solid Color Fill"
    case .linearGradientFillVideoComponent: "Linear Gradient Fill"
    case .radialGradientFillVideoComponent: "Radial Gradient Fill"
    case .conicGradientFillVideoComponent: "Conic Gradient Fill"
    case .clockVideoComponent: "Clock"
    case .testPatternVideoComponent: "Test Pattern"
    case .ocrVision: "OCR Vision"
    case .createMlImageClassificationVision: "Create ML Image Classification"
    }
  }

  private func observeToolbarState() {
    guard !isClosed else { return }
    withObservationTracking {
      if storeService.hasPendingSubmit { storeService.submitPendingEdits() }
      updateToolbarItems()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeToolbarState() }
    }
  }

  @objc private func toggleSidebar() {
    splitViewController.splitViewItems[0].isCollapsed.toggle()
  }

  @objc private func toggleInspector() {
    splitViewController.splitViewItems[2].isCollapsed.toggle()
  }

  @objc private func applyPendingEdits() {
    pendingEditsPopover.close()
    storeService.hasPendingSubmit = true
    updateToolbarItems()
  }

  private func showPendingEditsPopover(
    message: String = "Apply pending changes before selecting another item."
  ) {
    guard !isClosed else { return }
    splitViewController.splitViewItems[2].isCollapsed = false
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !isClosed,
        let item = toolbarItems[.init("workspace.inspector.apply")]
      else { return }
      contentView?.superview?.layoutSubtreeIfNeeded()
      pendingEditsPopover.close()
      pendingEditsPopover.behavior = .transient
      let controller = NSHostingController(
        rootView: Text(message)
          .padding().frame(width: 280))
      controller.sizingOptions = .preferredContentSize
      pendingEditsPopover.contentViewController = controller
      pendingEditsPopover.show(relativeTo: item)
    }
  }

  private var sidebarView: some View {
    WorkspaceSidebar(
      storeService: storeService, deviceRegistry: deviceRegistry, appletData: appletData
    )
    .environment(\.documentReference, documentReference)
  }

  private var inspectorView: some View {
    WorkspaceInspectorContainer(
      deviceRegistry: deviceRegistry,
      storeService: storeService,
      appletData: appletData
    )
    .environment(\.documentReference, documentReference)
  }

  @objc private func captureScreenshots() {
    do {
      let files = try storeService.captureScreenshots()
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
        storeService.reportError(error)
      }
    }
  }

  @discardableResult
  private func showScreenshotResult(
    title: String, message: String, screenshots: [WorkspaceScreenshot] = []
  ) -> Bool {
    guard
      let item = toolbar?.items.first(where: {
        $0.itemIdentifier.rawValue == "workspace.captureScreenshots"
      })
    else { return false }
    screenshotResultPopover.behavior = .transient
    let controller = NSHostingController(
      rootView: ScreenshotResultView(title: title, message: message, screenshots: screenshots))
    controller.sizingOptions = .preferredContentSize
    screenshotResultPopover.contentViewController = controller
    screenshotResultPopover.contentViewController?.view.setAccessibilityLabel(
      "\(title). \(message)")
    screenshotResultPopover.show(relativeTo: item)
    return true
  }

  public override func close() {
    isClosed = true
    pendingEditsPopover.close()
    storeService.pendingEditsDidBlockSelection = nil
    storeService.inputValidationErrorHandler = nil
    inspectorCollapseObservation?.invalidate()
    sidebarCollapseObservation?.invalidate()
    NotificationCenter.default.removeObserver(
      self, name: NSSplitView.didResizeSubviewsNotification,
      object: splitViewController.splitView)
    screenshotResultPopover.close()
    super.close()
  }

  @objc private func stopOutput() {
    guard storeService.recordingState.canStop else { return }
    Task { await storeService.stopOutput() }
  }

  @objc private func toggleOutput() {
    let state = storeService.recordingState
    guard state.canStart || state == .recording else { return }
    Task {
      if state == .recording {
        await storeService.pauseOutput()
      } else {
        do { try await storeService.startOutput() } catch {
          storeService.outputFailureMessage = error.localizedDescription
        }
      }
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
