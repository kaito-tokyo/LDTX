// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXWorkspaceAppletInterface

final class MasterVolumeEditor: NSViewController, NSMenuDelegate {
  private let monitorDevice = NSPopUpButton()
  private let storeService: WorkspaceStoreService

  init(storeService: WorkspaceStoreService) {
    self.storeService = storeService
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private let masters = [AudioChannelControlView(), AudioChannelControlView()]
  private(set) var masterFields = [AudioDecibelField(), AudioDecibelField()]
  private let monitorVolume = NSSlider(
    value: 0, minValue: ProgramPreferences.minimumAudioChannelGainDecibels,
    maxValue: ProgramPreferences.maximumAudioChannelGainDecibels, target: nil, action: nil)
  private let errorLabel = NSTextField(labelWithString: "")
  private var programID: UInt64?

  override func loadView() {
    view = NSView()
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 114 + 20 + 24).isActive = true
    let masterRows = (0..<2).map { index -> [NSView] in
      let name = index == 0 ? "Landscape" : "Portrait"
      let icon = NSImageView(
        image: NSImage(
          systemSymbolName: index == 0 ? "rectangle" : "rectangle.portrait",
          accessibilityDescription: name)!)
      icon.setAccessibilityLabel(name + " Volume")
      masterFields[index].widthAnchor.constraint(equalToConstant: 50).isActive = true
      return [icon, masters[index], masterFields[index], NSTextField(labelWithString: "dB")]
    }
    let grid = NSGridView(views: masterRows)
    grid.columnSpacing = 8
    grid.rowSpacing = 12
    grid.column(at: 0).width = 20
    grid.column(at: 2).width = 50
    grid.column(at: 3).width = 20
    for master in masters {
      master.widthAnchor.constraint(equalTo: grid.widthAnchor, constant: -114).isActive = true
    }
    monitorDevice.target = self
    monitorDevice.action = #selector(monitorDeviceChanged)
    monitorDevice.menu?.delegate = self
    refreshMonitorDevices()
    monitorVolume.target = self
    monitorVolume.action = #selector(monitorChanged)
    monitorVolume.isContinuous = true
    errorLabel.textColor = .systemRed
    let heading = NSTextField(labelWithString: "Master Volumes")
    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let separator = NSBox()
    separator.boxType = .separator
    let monitorRow = contentStack([monitorDevice, monitorVolume], vertical: false)
    let stack = contentStack([heading, grid, monitorRow, errorLabel, separator])
    pinContent(stack, in: view)
    for child in [grid, monitorRow, separator] {
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    refresh()
  }

  func menuWillOpen(_ menu: NSMenu) { refreshMonitorDevices() }

  private func refreshMonitorDevices() {
    let selected =
      UserDefaults.standard.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) ?? ""
    monitorDevice.removeAllItems()
    monitorDevice.addItem(withTitle: "System Default")
    monitorDevice.lastItem?.representedObject = ""
    if let devices = try? availableMonitorDevices() {
      for device in devices {
        monitorDevice.addItem(withTitle: device.name)
        monitorDevice.lastItem?.representedObject = device.uid
      }
    }
    if let item = monitorDevice.itemArray.first(where: {
      $0.representedObject as? String == selected
    }) {
      monitorDevice.select(item)
    } else {
      monitorDevice.addItem(withTitle: "Unavailable")
      monitorDevice.lastItem?.representedObject = selected
      monitorDevice.lastItem?.isEnabled = false
      monitorDevice.select(monitorDevice.lastItem)
    }
  }

  @objc private func monitorDeviceChanged() {
    guard let uid = monitorDevice.selectedItem?.representedObject as? String else { return }
    UserDefaults.standard.set(uid, forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
  }

  override func viewWillLayout() {
    super.viewWillLayout()
    refresh()
  }

  func refresh() {
    let peakMeter = storeService.audioPeakMeter
    _ = view
    let id = storeService.selectedProgram?.internalID
    if programID != id {
      for field in masterFields {
        field.discard()
      }
      view.window?.makeFirstResponder(nil)
      programID = id
      errorLabel.stringValue = ""
    }
    errorLabel.stringValue = storeService.editorFailureMessage ?? ""
    let enabled = id != nil
    for (index, target) in [WorkspaceCanvasTarget.landscape, .portrait].enumerated() {
      let preferences =
        id.flatMap { try? storeService.preferences(for: $0, target: target) } ?? .init()
      let value = Double(preferences.audioMasterVolumeDecibelTenths) / 10
      masters[index].configure(
        label: "", value: ProgramPreferences.linearAudioChannelGain(fromDecibels: value),
        showsValue: false, isEnabled: enabled,
        peakProvider: { peakMeter.peak(for: index == 0 ? .landscape : .portrait) },
        onPreview: { [weak storeService] gain in
          let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: gain)
          storeService?.updateAudio(target: target) {
            $0.audioMasterVolumeDecibelTenths = Int32((decibels * 10).rounded())
          }
        }, onCommit: { _ in })
      masterFields[index].configure(value: value, enabled: enabled) { [weak storeService] value in
        storeService?.updateAudio(target: target) {
          $0.audioMasterVolumeDecibelTenths = Int32((value * 10).rounded())
        } ?? false
      }
      masterFields[index].onInvalid = { [weak self] message in
        self?.errorLabel.stringValue = message
      }
    }
    monitorVolume.doubleValue = storeService.localState.monitorVolume ?? 0
    monitorVolume.isEnabled = storeService.canMonitor
  }
  @objc private func monitorChanged() {
    let value = monitorVolume.doubleValue
    storeService.updateMonitor { $0.monitorVolume = value }
  }

}

final class AudioDecibelField: NSTextField, NSTextFieldDelegate {
  private(set) var dirty = false
  private var editing = false
  private var commitValue: (Double) -> Bool = { _ in false }
  var onInvalid: (String) -> Void = { _ in }
  init() {
    super.init(frame: .zero)
    delegate = self
    setAccessibilityLabel("Master volume in dB")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func configure(value: Double, enabled: Bool, commit: @escaping (Double) -> Bool) {
    isEnabled = enabled
    commitValue = commit
    if !dirty && !editing { stringValue = String(format: "%.1f", value) }
  }
  func discard() {
    dirty = false
    editing = false
  }
  func controlTextDidBeginEditing(_ notification: Notification) { editing = true }
  func controlTextDidChange(_ notification: Notification) { dirty = true }
  func controlTextDidEndEditing(_ notification: Notification) {
    editing = false
    commit()
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
    commit()
    return true
  }
  func commit() {
    guard dirty else { return }
    guard let value = Double(stringValue), value.isFinite,
      (ProgramPreferences
        .minimumAudioChannelGainDecibels...ProgramPreferences.maximumAudioChannelGainDecibels)
        .contains(value)
    else {
      toolTip = "Invalid volume."
      onInvalid("Invalid volume.")
      return
    }
    if commitValue((value * 10).rounded() / 10) {
      dirty = false
      toolTip = nil
    }
  }
}
