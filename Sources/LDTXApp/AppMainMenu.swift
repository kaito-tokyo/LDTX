// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
final class AppMainMenu: NSMenu {
  init() {
    super.init(title: "LDTX")

    // MARK: - Application Menu

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(AppDelegate.showSettings(_:)),
      keyEquivalent: ",")

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
      action: #selector(AppDelegate.newWorkspace(_:)),
      keyEquivalent: "n")
    let openFileItem = NSMenuItem(
      title: "Open File…",
      action: #selector(AppDelegate.openFile(_:)),
      keyEquivalent: "o")
    let saveItem = NSMenuItem(
      title: "Save",
      action: #selector(AppDelegate.save(_:)),
      keyEquivalent: "s")
    let saveAsItem = NSMenuItem(
      title: "Save As…",
      action: #selector(AppDelegate.saveAs(_:)),
      keyEquivalent: "S")
    let reloadItem = NSMenuItem(
      title: "Reload Workspace",
      action: #selector(AppDelegate.reload(_:)),
      keyEquivalent: "")

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
        action: #selector(AppDelegate.toggleInspector(_:)),
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
      action: #selector(AppDelegate.crashReports(_:)),
      keyEquivalent: "")

    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(crashReportsItem)
    let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    addItem(helpMenuItem)

    NSApp.servicesMenu = servicesMenuItem.submenu
    NSApp.windowsMenu = windowMenu
  }

  required init(coder: NSCoder) {
    fatalError("AppMainMenu does not support coder initialization")
  }

}
