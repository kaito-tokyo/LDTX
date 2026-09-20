// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceApplet

@MainActor
final class ApplicationMainMenu: NSMenu {
  private weak var router: ApplicationRouter?
  private let showSettingsAction: () -> Void

  init(router: ApplicationRouter, showSettings: @escaping () -> Void) {
    self.router = router
    self.showSettingsAction = showSettings
    super.init(title: "LDTX")

    // MARK: - Application Menu

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(showSettings(_:)),
      keyEquivalent: ",")
    settingsItem.target = self

    let servicesMenuItem = NSMenuItem(
      title: "Services",
      action: nil,
      keyEquivalent: "")
    servicesMenuItem.submenu = NSMenu(title: "Services")

    let applicationMenu = NSMenu(title: "LDTX")
    [
      NSMenuItem(
        title: "About LDTX",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""),
      settingsItem,
      .separator(),
      servicesMenuItem,
      NSMenuItem(
        title: "Hide LDTX",
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"),
      NSMenuItem(
        title: "Show All",
        action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""),
      .separator(),
      NSMenuItem(
        title: "Quit LDTX",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"),
    ].forEach(applicationMenu.addItem)
    let applicationMenuItem = NSMenuItem(title: "LDTX", action: nil, keyEquivalent: "")
    applicationMenuItem.submenu = applicationMenu
    addItem(applicationMenuItem)

    // MARK: - File Menu

    let newWorkspaceItem = NSMenuItem(
      title: "New Workspace",
      action: #selector(ApplicationRouter.newWorkspace),
      keyEquivalent: "n")
    newWorkspaceItem.target = router
    let openFileItem = NSMenuItem(
      title: "Open File…",
      action: #selector(ApplicationRouter.openFile),
      keyEquivalent: "o")
    openFileItem.target = router
    let saveItem = NSMenuItem(
      title: "Save",
      action: #selector(ApplicationRouter.save),
      keyEquivalent: "s")
    saveItem.target = router
    let saveAsItem = NSMenuItem(
      title: "Save As…",
      action: #selector(ApplicationRouter.saveAs),
      keyEquivalent: "S")
    saveAsItem.target = router
    let reloadItem = NSMenuItem(
      title: "Reload Workspace",
      action: #selector(ApplicationRouter.reload),
      keyEquivalent: "")
    reloadItem.target = router

    let fileMenu = NSMenu(title: "File")
    [
      newWorkspaceItem,
      openFileItem,
      NSMenuItem(
        title: "Close",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"),
      saveItem,
      saveAsItem,
      reloadItem,
    ].forEach(fileMenu.addItem)
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu
    addItem(fileMenuItem)

    // MARK: - Edit Menu

    let editMenu = NSMenu(title: "Edit")
    [
      NSMenuItem(
        title: "Undo",
        action: #selector(UndoManager.undo),
        keyEquivalent: "z"),
      NSMenuItem(
        title: "Redo",
        action: #selector(UndoManager.redo),
        keyEquivalent: "Z"),
      NSMenuItem(
        title: "Cut",
        action: #selector(NSText.cut(_:)),
        keyEquivalent: "x"),
      NSMenuItem(
        title: "Copy",
        action: #selector(NSText.copy(_:)),
        keyEquivalent: "c"),
      NSMenuItem(
        title: "Paste",
        action: #selector(NSText.paste(_:)),
        keyEquivalent: "v"),
      NSMenuItem(
        title: "Select All",
        action: #selector(NSResponder.selectAll(_:)),
        keyEquivalent: "a"),
    ].forEach(editMenu.addItem)
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editMenuItem.submenu = editMenu
    addItem(editMenuItem)

    // MARK: - View Menu

    let viewMenu = NSMenu(title: "View")
    [
      NSMenuItem(
        title: "Toggle Inspector",
        action: #selector(WorkspaceV4WindowController.toggleInspector),
        keyEquivalent: "")
    ].forEach(viewMenu.addItem)
    let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    viewMenuItem.submenu = viewMenu
    addItem(viewMenuItem)

    // MARK: - Window Menu

    let windowMenu = NSMenu(title: "Window")
    [
      NSMenuItem(
        title: "Minimize",
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"),
      NSMenuItem(
        title: "Zoom",
        action: #selector(NSWindow.performZoom(_:)),
        keyEquivalent: ""),
    ].forEach(windowMenu.addItem)
    let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    addItem(windowMenuItem)

    // MARK: - Help Menu

    let crashReportsItem = NSMenuItem(
      title: "Show Crash Reports in Finder",
      action: #selector(ApplicationRouter.crashReports),
      keyEquivalent: "")
    crashReportsItem.target = router

    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(crashReportsItem)
    let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    addItem(helpMenuItem)

    NSApp.servicesMenu = servicesMenuItem.submenu
    NSApp.windowsMenu = windowMenu
  }

  required init(coder: NSCoder) {
    fatalError("ApplicationMainMenu does not support coder initialization")
  }

  @objc private func showSettings(_ sender: Any?) {
    showSettingsAction()
  }

}
