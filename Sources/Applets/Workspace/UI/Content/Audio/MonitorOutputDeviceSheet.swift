// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreAudio
import LDTXWorkspaceAppletInterface

final class MonitorOutputDeviceSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate
{
  let table = NSTableView()
  let currentLabel = NSTextField(labelWithString: "")
  private let errorLabel = NSTextField(labelWithString: "")
  private let failureLabel = NSTextField(wrappingLabelWithString: "")
  let applyButton = ContentActionButton("Apply")
  private var devices: [(uid: String, name: String)] = []
  private(set) var selectedUID: String?
  private let deviceProvider: () throws -> [(uid: String, name: String)]
  private let defaults: UserDefaults
  private var loadError: String?
  private var refreshing = false
  private var observer: NSObjectProtocol?
  var onClose: () -> Void = {}

  init(
    defaults: UserDefaults = .standard,
    deviceProvider: @escaping () throws -> [(uid: String, name: String)] = {
      try availableMonitorDevices()
    }
  ) {
    self.defaults = defaults
    self.deviceProvider = deviceProvider
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 390), styleMask: [.titled],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Monitor Device"
    table.addTableColumn(NSTableColumn(identifier: .init("device")))
    table.headerView = nil
    table.dataSource = self
    table.delegate = self
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    let refresh = ContentActionButton("Refresh") { [weak self] in self?.refreshDevices() }
    let systemDefault = ContentActionButton("Use System Default") { [weak self] in self?.submit(nil)
    }
    let cancel = ContentActionButton("Cancel") { [weak self] in self?.onClose() }
    cancel.keyEquivalent = "\u{1b}"
    applyButton.keyEquivalent = "\r"
    applyButton.invoke = { [weak self] in
      guard let self, let uid = selectedUID else { return }
      submit(uid)
    }
    let stack = contentStack([
      currentLabel, scroll, errorLabel, failureLabel,
      contentStack([refresh, systemDefault, cancel, applyButton], vertical: false),
    ])
    pinContent(stack, in: window.contentView!)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
    errorLabel.textColor = .systemRed
    failureLabel.textColor = .systemRed
    observer = NotificationCenter.default.addObserver(
      forName: WorkspaceAudioEngine.statusDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStatus() }
    }
    refreshDevices()
    refreshStatus()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
  private func refreshStatus() {
    failureLabel.stringValue = WorkspaceAudioEngine.failureMessages.joined(separator: "\n")
  }
  func refreshDevices() {
    do {
      devices = try deviceProvider().sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      loadError = nil
    } catch {
      devices = []
      loadError = error.localizedDescription
    }
    if let selectedUID, !devices.contains(where: { $0.uid == selectedUID }) {
      self.selectedUID = nil
    }
    refreshing = true
    defer { refreshing = false }
    table.reloadData()
    if let selectedUID, let index = devices.firstIndex(where: { $0.uid == selectedUID }) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    let current =
      defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) ?? ""
    currentLabel.stringValue =
      current.isEmpty
      ? "System Default" : devices.first { $0.uid == current }?.name ?? "Unavailable"
    errorLabel.stringValue = loadError ?? ""
    applyButton.isEnabled = selectedUID != nil && loadError == nil
  }
  func numberOfRows(in tableView: NSTableView) -> Int { devices.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard devices.indices.contains(row) else { return nil }
    return NSTextField(labelWithString: devices[row].name)
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !refreshing else { return }
    selectedUID = devices.indices.contains(table.selectedRow) ? devices[table.selectedRow].uid : nil
    applyButton.isEnabled = selectedUID != nil && loadError == nil
  }
  private func submit(_ uid: String?) {
    if let uid {
      refreshDevices()
      guard loadError == nil, devices.contains(where: { $0.uid == uid }) else {
        errorLabel.stringValue = loadError ?? "The selected monitor device is unavailable."
        return
      }
    }
    defaults.set(uid ?? "", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
    onClose()
  }
}

@MainActor
func availableMonitorDevices() throws -> [(uid: String, name: String)] {
  try AudioHardwareSystem.shared.devices.compactMap { device in
    guard try device.outputStreamConfiguration.contains(where: { $0.mNumberChannels > 0 }) else {
      return nil
    }
    return (try device.uid, try device.name)
  }
}
