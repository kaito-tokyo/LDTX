// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import Observation
import QuickLookThumbnailing
import SwiftUI

public final class WorkspaceWindow: NSWindow, NSToolbarDelegate, NSToolbarItemValidation {
  let contentPane: WorkspaceContentPane
  private let storeService: WorkspaceStoreService
  let screenshotResultPopover = NSPopover()

  init(
    url: URL,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData,
    storeService: WorkspaceStoreService,
    documentReference: DocumentReference,
    pairedPreview: ProgramCanvasPairedPreview
  ) {
    self.storeService = storeService
    storeService.appletData = appletData
    storeService.documentReference = documentReference
    self.contentPane = WorkspaceContentPane(
      storeService: storeService,
      pairedPreview: pairedPreview)

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)

    self.representedURL = url
    self.title = url.deletingPathExtension().lastPathComponent
    self.isReleasedWhenClosed = false

    let sidebarView = WorkspaceSidebar(
      storeService: storeService, deviceRegistry: deviceRegistry, appletData: appletData
    )

    let inspectorView = WorkspaceInspectorContainer(
      deviceRegistry: deviceRegistry,
      storeService: storeService,
      appletData: appletData
    )

    let sidebarController = NSHostingController(
      rootView: sidebarView.environment(\.documentReference, documentReference))
    sidebarController.sizingOptions = [.minSize]

    let inspectorController = NSHostingController(
      rootView: inspectorView.environment(\.documentReference, documentReference))
    inspectorController.sizingOptions = [.minSize]

    let splitViewController = PaneSplitViewController(
      sidebar: sidebarController, content: contentPane, inspector: inspectorController,
      sidebarCanCollapse: true)

    self.contentViewController = splitViewController
    self.titleVisibility = .visible
    self.toolbarStyle = .unified
    let toolbar = NSToolbar(identifier: "WorkspaceV4Toolbar.AppKit.v1")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    self.toolbar = toolbar
    // Installing the content controller replaces the initial size with its fitting size.
    let toolbarHeight = frame.height - contentLayoutRect.height
    self.setFrame(
      NSRect(origin: frame.origin, size: NSSize(width: 1062, height: 700 + toolbarHeight)),
      display: false)

    splitViewController.setInitialWidths(sidebar: 240, content: 480)
    contentPane.configureAfterEstablished()

    self.center()
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .init("workspace.sidebar"), .sidebarTrackingSeparator,
      .init("workspace.stopOutput"), .init("workspace.toggleOutput"),
      .init("workspace.captureScreenshots"),
      .flexibleSpace,
      .inspectorTrackingSeparator, .flexibleSpace, .init("workspace.inspector"),
    ]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  public func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.target = contentViewController
    switch identifier.rawValue {
    case "workspace.sidebar":
      item.label = "Sidebar"
      item.paletteLabel = "Sidebar"
      item.toolTip = "Show or hide the Sidebar"
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
      item.action = #selector(PaneSplitViewController.toggleSidebar(_:))
    case "workspace.stopOutput":
      configureOutputItem(item)
      item.isNavigational = true
      item.target = self
      item.action = #selector(stopOutput(_:))
    case "workspace.toggleOutput":
      configureOutputItem(item)
      item.isNavigational = true
      item.target = self
      item.action = #selector(toggleOutput(_:))
    case "workspace.captureScreenshots":
      item.isNavigational = true
      item.label = "Capture Screenshot(s)"
      item.paletteLabel = item.label
      item.toolTip = item.label
      item.image = NSImage(systemSymbolName: "camera", accessibilityDescription: item.label)
      item.target = self
      item.action = #selector(captureScreenshots(_:))
      item.isEnabled = validateToolbarItem(item)
    case "workspace.inspector":
      item.label = "Inspector"
      item.paletteLabel = "Inspector"
      item.toolTip = "Show or hide the Inspector"
      item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
      item.action = #selector(PaneSplitViewController.toggleInspector(_:))
    default:
      return nil
    }
    return item
  }

  private func configureOutputItem(_ item: NSToolbarItem) {
    let isStop = item.itemIdentifier.rawValue == "workspace.stopOutput"
    let isRunning = storeService.recordingState == .recording
    let label = isStop ? "Stop Output" : (isRunning ? "Pause Output" : "Start Output")
    let symbol = isStop ? "stop.fill" : (isRunning ? "pause.fill" : "play.fill")
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.isEnabled = validateToolbarItem(item)
  }

  func updateOutputToolbar() {
    for item in toolbar?.items ?? [] where item.target === self {
      switch item.itemIdentifier.rawValue {
      case "workspace.stopOutput", "workspace.toggleOutput": configureOutputItem(item)
      default: item.isEnabled = validateToolbarItem(item)
      }
    }
  }

  public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    switch item.itemIdentifier.rawValue {
    case "workspace.stopOutput": storeService.recordingState.canStop
    case "workspace.toggleOutput":
      storeService.recordingState.canStart || storeService.recordingState == .recording
    default: true
    }
  }

  @objc private func captureScreenshots(_ sender: Any?) {
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
    screenshotResultPopover.close()
    super.close()
  }

  @objc private func stopOutput(_ sender: Any?) {
    guard storeService.recordingState.canStop else { return }
    Task { await storeService.stopOutput() }
  }

  @objc private func toggleOutput(_ sender: Any?) {
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
