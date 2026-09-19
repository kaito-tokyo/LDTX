// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceApplet

@MainActor
final class ApplicationMainMenu: NSMenu {
  private weak var router: ApplicationRouter?

  private let applicationMenu = NSMenu(title: "LDTX")
  private let fileMenu = NSMenu(title: "File")
  private let editMenu = NSMenu(title: "Edit")
  private let viewMenu = NSMenu(title: "View")
  private let windowMenu = NSMenu(title: "Window")
  private let helpMenu = NSMenu(title: "Help")

  private let applicationMenuItem = NSMenuItem(title: "LDTX", action: nil, keyEquivalent: "")
  private let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
  private let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
  private let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
  private let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
  private let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
  private let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
  private let settingsItem = NSMenuItem(
    title: "Settings…", action: #selector(ApplicationRouter.showSettings), keyEquivalent: ",")
  private let newWorkspaceItem = NSMenuItem(
    title: "New Workspace", action: #selector(ApplicationRouter.newWorkspace), keyEquivalent: "n")
  private let openFileItem = NSMenuItem(
    title: "Open File…", action: #selector(ApplicationRouter.openFile), keyEquivalent: "o")
  private let saveItem = NSMenuItem(
    title: "Save", action: #selector(ApplicationRouter.save), keyEquivalent: "s")
  private let saveAsItem = NSMenuItem(
    title: "Save As…", action: #selector(ApplicationRouter.saveAs), keyEquivalent: "S")
  private let reloadItem = NSMenuItem(
    title: "Reload Workspace", action: #selector(ApplicationRouter.reload), keyEquivalent: "")
  private let inspectorItem = NSMenuItem(
    title: "Toggle Inspector", action: #selector(WorkspaceV4WindowController.toggleInspector),
    keyEquivalent: "")
  private let crashReportsItem = NSMenuItem(
    title: "Show Crash Reports in Finder", action: #selector(ApplicationRouter.crashReports),
    keyEquivalent: "")

  init(router: ApplicationRouter) {
    self.router = router
    super.init(title: "LDTX")
    configureTargets()
    buildMenus()
    NSApp.servicesMenu = servicesMenuItem.submenu
    NSApp.windowsMenu = windowMenu
  }

  required init(coder: NSCoder) {
    fatalError("ApplicationMainMenu does not support coder initialization")
  }

  private func configureTargets() {
    settingsItem.target = router
    newWorkspaceItem.target = router
    openFileItem.target = router
    saveItem.target = router
    saveAsItem.target = router
    reloadItem.target = router
    crashReportsItem.target = router
  }

  private func buildMenus() {
    applicationMenuItem.submenu = applicationMenu
    fileMenuItem.submenu = fileMenu
    editMenuItem.submenu = editMenu
    viewMenuItem.submenu = viewMenu
    windowMenuItem.submenu = windowMenu
    helpMenuItem.submenu = helpMenu
    addItem(applicationMenuItem)
    addItem(fileMenuItem)
    addItem(editMenuItem)
    addItem(viewMenuItem)
    addItem(windowMenuItem)
    addItem(helpMenuItem)

    buildApplicationMenu()
    buildFileMenu()
    buildEditMenu()
    buildViewMenu()
    buildWindowMenu()
    buildHelpMenu()
  }

  private func buildApplicationMenu() {
    applicationMenu.addItem(
      NSMenuItem(
        title: "About LDTX", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""))
    applicationMenu.addItem(settingsItem)
    applicationMenu.addItem(.separator())
    servicesMenuItem.submenu = NSMenu(title: "Services")
    applicationMenu.addItem(servicesMenuItem)
    applicationMenu.addItem(
      NSMenuItem(title: "Hide LDTX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    applicationMenu.addItem(
      NSMenuItem(
        title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""))
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      NSMenuItem(
        title: "Quit LDTX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  }

  private func buildFileMenu() {
    fileMenu.addItem(newWorkspaceItem)
    fileMenu.addItem(openFileItem)
    fileMenu.addItem(
      NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    fileMenu.addItem(saveItem)
    fileMenu.addItem(saveAsItem)
    fileMenu.addItem(reloadItem)
  }

  private func buildEditMenu() {
    editMenu.addItem(
      NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
    editMenu.addItem(
      NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z"))
    editMenu.addItem(
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(
      NSMenuItem(
        title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
  }

  private func buildViewMenu() { viewMenu.addItem(inspectorItem) }

  private func buildWindowMenu() {
    windowMenu.addItem(
      NSMenuItem(
        title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    windowMenu.addItem(
      NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
  }

  private func buildHelpMenu() { helpMenu.addItem(crashReportsItem) }
}
