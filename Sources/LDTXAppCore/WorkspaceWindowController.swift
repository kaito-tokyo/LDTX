// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppKitUI
import LDTXAppUI
import Observation
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSWindowController, NSToolbarDelegate {
  let session: WorkspaceSession
  let split: PaneSplitViewController
  private var buttons: [String: NSButton] = [:]
  private var toolbarActions: [WorkspaceView.ToolbarAction] = []
  private var menuActions: [WorkspaceView.ToolbarAction] = []
  private let programPicker = NSSegmentedControl()
  private let manageProgramsLabel = NSTextField(labelWithString: "Manage Programs")
  private var programItem: NSToolbarItem?
  private var externalToolsItem: NSMenuToolbarItem?
  private var started = false
  private var alertIsPresented = false

  init(session: WorkspaceSession) {
    self.session = session
    split = PaneSplitViewController(
      sidebar: paneHost(WorkspacePaneAdapter(session: session, pane: .sidebar)),
      content: paneHost(WorkspacePaneAdapter(session: session, pane: .content)),
      inspector: paneHost(WorkspacePaneAdapter(session: session, pane: .inspector)),
      sidebarCanCollapse: true)
    let window = PaneWindow(contentViewController: split)
    window.title = "Workspace"
    window.titleVisibility = .hidden
    window.setContentSize(NSSize(width: 1062, height: 700))
    window.center()
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    super.init(window: window)
    session.onClose = { [weak self] in
      guard let self else { return }
      // A failed initial load has no user edits to confirm. Stop its resources
      // before closing, without offering to save an uninitialized workspace.
      Task { @MainActor in
        await self.session.shutdown()
        self.close()
      }
    }
    session.attach(to: window)
    let toolbar = NSToolbar(identifier: "WorkspaceToolbar.AppKit.v1")
    toolbar.displayMode = .iconOnly
    toolbar.delegate = self
    window.toolbar = toolbar
    split.setInitialWidths(sidebar: 240, content: 480)
    window.setFrameAutosaveName("Workspace.AppKit.v1")
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  func start() {
    guard !started else { return }
    started = true
    session.start()
    observeIdentity()
    refreshToolbar()
    presentPendingAlert()
  }

  var identityChanged: ((WorkspaceWindowRequest) -> Void)?
  private func observeIdentity() {
    let request = withObservationTracking {
      session.request
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeIdentity() }
    }
    if let window = window as? PaneWindow {
      if case .file(let url) = request.source {
        window.title = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        window.restorationURL = url
        window.restorationKind = "workspace"
        window.identifier =
          window.identifier
          ?? NSUserInterfaceItemIdentifier("Workspace.AppKit.v1." + UUID().uuidString)
        window.restorationClass = ApplicationWindowRestorer.self
        window.isRestorable = true
      } else {
        window.isRestorable = false
      }
      window.invalidateRestorableState()
    }
    identityChanged?(request)
  }

  private func presentPendingAlert() {
    guard !alertIsPresented, let window else { return }
    let pending = withObservationTracking {
      session.pendingAlert
    } onChange: { [weak self] in
      Task { @MainActor in self?.presentPendingAlert() }
    }
    guard let pending else { return }
    let alert = NSAlert()
    alert.messageText = pending.title
    alert.informativeText = pending.message
    alert.addButton(withTitle: "OK")
    alertIsPresented = true
    alert.beginSheetModal(for: window) { [weak self] _ in
      pending.dismiss()
      self?.alertIsPresented = false
    }
  }

  private func refreshToolbar() {
    let value = withObservationTracking {
      let view = session.workspaceView
      return (
        toolbarActions: view.toolbarActions, externalToolActions: view.externalToolActions,
        programNames: view.programNames, selectedProgram: view.activeProgram.wrappedValue,
        programSwitchEnabled: view.programSwitchEnabled, managesPrograms: view.managesPrograms,
        programSwitchStatus: view.programSwitchStatus
      )
    } onChange: { [weak self] in
      Task { @MainActor in self?.refreshToolbar() }
    }
    toolbarActions = value.toolbarActions
    for (id, button) in buttons where id != "toolbarInspectorButton" && id != "toolbarSidebarButton" {
      button.isEnabled = false

    }
    for action in toolbarActions {
      if let button = buttons[action.id] {
        button.image = NSImage(
          systemSymbolName: action.symbol, accessibilityDescription: action.title)
        button.isEnabled = action.enabled
        button.toolTip = action.title
        button.setAccessibilityLabel(action.title)
      }
    }
    programPicker.segmentCount = value.programNames.count
    for (index, name) in value.programNames.enumerated() {
      programPicker.setLabel(name, forSegment: index)
      programPicker.setSelected(name == value.selectedProgram, forSegment: index)
    }
    programPicker.isEnabled = value.programSwitchEnabled
    programItem?.view = value.managesPrograms ? manageProgramsLabel : programPicker
    programPicker.setAccessibilityValue("Output is " + value.programSwitchStatus)
    programPicker.sizeToFit()
    menuActions = value.externalToolActions
    externalToolsItem?.isEnabled = menuActions.contains(where: \.enabled)
    for item in externalToolsItem?.menu.items ?? [] {
      item.isEnabled = menuActions.indices.contains(item.tag) && menuActions[item.tag].enabled
    }
    window?.toolbar?.itemIdentifiers = toolbarIdentifiers(
      actions: toolbarActions, managesPrograms: value.managesPrograms)
  }

  private func toolbarIdentifiers(
    actions: [WorkspaceView.ToolbarAction], managesPrograms: Bool
  ) -> [NSToolbarItem.Identifier] {
    var identifiers: [NSToolbarItem.Identifier] = [
      .init("toolbarSidebarButton"), .init("sidebarSeparator")]
    identifiers += actions.map { NSToolbarItem.Identifier($0.id) }
    if !managesPrograms { identifiers.append(.init("toolbarExternalToolsMenu")) }
    identifiers += [.init("programSwitcher"), .flexibleSpace, .init("toolbarInspectorButton")]
    return identifiers
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarIdentifiers(
      actions: session.workspaceView.toolbarActions,
      managesPrograms: session.workspaceView.managesPrograms)
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar) + [.init("renameWorkspaceResourceButton"), .init("toolbarAnalyzeVisionButton")]
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if id.rawValue == "sidebarSeparator" {
      return NSTrackingSeparatorToolbarItem(
        identifier: id, splitView: split.splitView, dividerIndex: 0)
    }
    let item: NSToolbarItem = id.rawValue == "toolbarExternalToolsMenu"
      ? NSMenuToolbarItem(itemIdentifier: id) : NSToolbarItem(itemIdentifier: id)
    item.label =
      session.workspaceView.toolbarActions.first(where: { $0.id == id.rawValue })?.title
      ?? [
        "programSwitcher": "Program", "toolbarExternalToolsMenu": "External Tools",
        "renameWorkspaceResourceButton": "Rename…",
        "toolbarAnalyzeVisionButton": "Analyze Current Frame",
        "toolbarInspectorButton": "Inspector",
        "toolbarSidebarButton": "Sidebar",
      ][id.rawValue] ?? ""
    if id.rawValue == "programSwitcher" {
      programPicker.target = self
      programPicker.action = #selector(changeProgram)
      programPicker.segmentStyle = .texturedRounded
      programPicker.trackingMode = .selectOne
      programPicker.controlSize = .small
      programPicker.selectedSegmentBezelColor = .controlAccentColor
      programPicker.setAccessibilityIdentifier("activeProgramSegmentedControl")
      programPicker.setAccessibilityLabel("Program Switcher")
      programItem = item
      item.view = session.workspaceView.managesPrograms ? manageProgramsLabel : programPicker
    } else if id.rawValue == "toolbarExternalToolsMenu" {
      guard let menuItem = item as? NSMenuToolbarItem else { return nil }
      externalToolsItem = menuItem
      menuItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "External Tools")
      menuItem.toolTip = "External Tools"
      menuItem.menu = NSMenu()
      menuItem.menu.autoenablesItems = false
      menuItem.autovalidates = false
      for (index, action) in session.workspaceView.externalToolActions.enumerated() {
        let menu = NSMenuItem(
          title: action.title, action: #selector(externalTool), keyEquivalent: "")
        menu.target = self
        menu.tag = index
        menu.isEnabled = action.enabled
        menuItem.menu.addItem(menu)
      }
      menuItem.isEnabled = session.workspaceView.externalToolActions.contains(where: \.enabled)
    } else {
      let button = NSButton(
        image: NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!, target: self,
        action: #selector(performAction))
      button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
      button.setAccessibilityIdentifier(id.rawValue)
      button.bezelStyle = .texturedRounded
      buttons[id.rawValue] = button
      if let action = session.workspaceView.toolbarActions.first(where: { $0.id == id.rawValue }) {
        button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
        button.isEnabled = action.enabled
        button.toolTip = action.title
        button.setAccessibilityLabel(action.title)
      }
      if id.rawValue == "toolbarSidebarButton" {
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
        button.toolTip = "Toggle Sidebar"
        button.setAccessibilityLabel("Toggle Sidebar")
      }
      if id.rawValue == "toolbarInspectorButton" {
        button.image = NSImage(
          systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")
        button.toolTip = "Toggle Inspector"
      }
      item.view = button
    }
    return item
  }
  @objc private func performAction(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    if id == "toolbarSidebarButton" {
      split.toggleSidebar(sender)
      return
    }
    if id == "toolbarInspectorButton" {
      split.toggleInspector(sender)
      return
    }
    if let action = toolbarActions.first(where: { $0.id == id }), action.enabled {
      action.perform()
    }
  }
  @objc private func changeProgram(_ sender: NSSegmentedControl) {
    let names = session.workspaceView.programNames
    guard names.indices.contains(sender.selectedSegment) else { return }
    session.workspaceView.activeProgram.wrappedValue = names[sender.selectedSegment]
  }
  @objc private func externalTool(_ sender: NSMenuItem) {
    guard menuActions.indices.contains(sender.tag), menuActions[sender.tag].enabled else { return }
    menuActions[sender.tag].perform()
  }
}

private struct WorkspacePaneAdapter: View {
  let session: WorkspaceSession
  let pane: WorkspacePane
  private var workspaceTitle: String {
    if case .file(let url) = session.request.source {
      return url.deletingPathExtension().lastPathComponent
    }
    return "Workspace"
  }

  var body: some View {
    if pane == .content {
      VStack(alignment: .leading, spacing: 0) {
        Text(workspaceTitle)
          .font(.title2.weight(.semibold))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("workspaceTitle")
          .help(workspaceTitle)
        session.pane(pane)
      }
    } else {
      session.pane(pane)
    }
  }
}
