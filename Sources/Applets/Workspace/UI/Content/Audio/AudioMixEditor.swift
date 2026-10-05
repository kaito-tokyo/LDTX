// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXWorkspaceAppletInterface

final class AudioMixEditor: NSViewController {
  weak var content: WorkspaceContent?
  let targetSelector = NSSegmentedControl(
    labels: ["Landscape", "Portrait"], trackingMode: .selectOne, target: nil, action: nil)
  let errorLabel = NSTextField(labelWithString: "")
  let outputErrorLabel = NSTextField(wrappingLabelWithString: "")
  private let masters = [AudioChannelControlView(), AudioChannelControlView()]
  private(set) var masterFields = [AudioDecibelField(), AudioDecibelField()]
  private let monitorVolume = NSSlider(
    value: 0, minValue: ProgramPreferences.minimumAudioChannelGainDecibels,
    maxValue: ProgramPreferences.maximumAudioChannelGainDecibels, target: nil, action: nil)
  private let channels = contentStack([])
  private var rows: [UInt64: AudioInputRow] = [:]
  private var programID: UInt64?
  private var monitorSheet: MonitorOutputDeviceSheet?

  override func loadView() {
    view = NSView()
    let masterRows = (0..<2).map { index -> NSView in
      let row = contentStack(
        [
          NSTextField(labelWithString: index == 0 ? "Landscape" : "Portrait"), masters[index],
          masterFields[index], NSTextField(labelWithString: "dB"),
        ], vertical: false)
      masterFields[index].widthAnchor.constraint(equalToConstant: 60).isActive = true
      masters[index].widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.5).isActive =
        true
      return row
    }
    let monitorButton = ContentActionButton("Monitor Device…") { [weak self] in self?.openMonitor()
    }
    monitorVolume.target = self
    monitorVolume.action = #selector(monitorChanged)
    monitorVolume.isContinuous = true
    targetSelector.target = self
    targetSelector.action = #selector(targetChanged)
    errorLabel.textColor = .systemRed
    outputErrorLabel.textColor = .systemRed
    let stack = contentStack(
      [NSTextField(labelWithString: "Master Volumes")] + masterRows + [
        contentStack([monitorButton, monitorVolume], vertical: false),
        NSTextField(labelWithString: "Audio Mix"), targetSelector, channels,
        errorLabel, outputErrorLabel,
      ])
    pinContent(stack, in: view)
    for row in masterRows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    channels.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  func refresh(peakMeter: ProgramAudioPeakMeter) {
    _ = view
    guard let content else { return }
    let id = content.selectedProgram?.internalID
    if programID != id {
      masterFields.forEach { $0.discard() }
      view.window?.makeFirstResponder(nil)
      programID = id
      errorLabel.stringValue = ""
    }
    let enabled = id != nil
    for (index, target) in [WorkspaceCanvasTarget.landscape, .portrait].enumerated() {
      let preferences = id.flatMap { try? content.preferences(for: $0, target: target) } ?? .init()
      let value = Double(preferences.audioMasterVolumeDecibelTenths) / 10
      masters[index].configure(
        label: "", value: ProgramPreferences.linearAudioChannelGain(fromDecibels: value),
        showsValue: false, isEnabled: enabled,
        peakProvider: { peakMeter.peak(for: index == 0 ? .landscape : .portrait) },
        onPreview: { [weak content] gain in
          let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: gain)
          content?.updateAudio(target: target) {
            $0.audioMasterVolumeDecibelTenths = Int32((decibels * 10).rounded())
          }
        }, onCommit: { _ in })
      masterFields[index].configure(value: value, enabled: enabled) { [weak content] value in
        content?.updateAudio(target: target) {
          $0.audioMasterVolumeDecibelTenths = Int32((value * 10).rounded())
        } ?? false
      }
      masterFields[index].onInvalid = { [weak self] message in
        self?.errorLabel.stringValue = message
      }
    }
    targetSelector.selectedSegment = content.uiState.selectedAudioMix == .portrait ? 1 : 0
    monitorVolume.doubleValue = content.localState.monitorVolume ?? 0
    monitorVolume.isEnabled = content.canMonitor
    let inputs = content.uiState.definition.audioDevices
    let ids = Set(inputs.map(\.internalID))
    for id in Array(rows.keys) where !ids.contains(id) {
      if let row = rows.removeValue(forKey: id) {
        channels.removeArrangedSubview(row)
        row.removeFromSuperview()
      }
    }
    for (index, input) in inputs.enumerated() {
      let row = rows[input.internalID] ?? AudioInputRow()
      if rows[input.internalID] == nil {
        rows[input.internalID] = row
        channels.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: channels.widthAnchor).isActive = true
      }
      if channels.arrangedSubviews[index] !== row {
        channels.removeArrangedSubview(row)
        channels.insertArrangedSubview(row, at: index)
      }
      row.configure(input: input, content: content, peakMeter: peakMeter)
    }
  }
  @objc private func targetChanged() {
    content?.selectAudioMix(targetSelector.selectedSegment == 1)
  }
  @objc private func monitorChanged() {
    let value = monitorVolume.doubleValue
    content?.updateMonitor { $0.monitorVolume = value }
  }
  private func openMonitor() {
    guard monitorSheet == nil, let window = view.window else { return }
    let sheet = MonitorOutputDeviceSheet()
    sheet.onClose = { [weak self] in self?.closeMonitor() }
    monitorSheet = sheet
    window.beginSheet(sheet.window!)
  }
  private func closeMonitor() {
    guard let sheet = monitorSheet else { return }
    sheet.stop()
    if let window = sheet.window, let parent = window.sheetParent { parent.endSheet(window) }
    sheet.window?.orderOut(nil)
    monitorSheet = nil
  }
  func stop() {
    closeMonitor()
    for master in masters {
      master.configure(
        label: "", value: 1, peakProvider: nil, onPreview: { _ in }, onCommit: { _ in })
    }
    rows.values.forEach { $0.stop() }
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

private final class AudioInputRow: NSStackView {
  let landscape = ContentActionButton("Landscape", checkbox: true)
  let portrait = ContentActionButton("Portrait", checkbox: true)
  let monitor = ContentActionButton("Monitor", checkbox: true)
  let name = NSTextField(labelWithString: "")
  let gain = AudioChannelControlView()
  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 4
    let heading = contentStack([name, landscape, portrait, monitor], vertical: false)
    addArrangedSubview(heading)
    addArrangedSubview(gain)
    heading.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    gain.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func configure(
    input: Ldtx_Workspace_V4_AudioInputDevice, content: WorkspaceContent,
    peakMeter: ProgramAudioPeakMeter
  ) {
    let id = input.internalID
    name.stringValue = input.displayName
    for (target, button) in [(WorkspaceCanvasTarget.landscape, landscape), (.portrait, portrait)] {
      let preferences =
        content.selectedProgram.flatMap {
          try? content.preferences(for: $0.internalID, target: target)
        } ?? .init()
      button.state = preferences.audioChannelMuted[id] == true ? .off : .on
      button.isEnabled = content.selectedProgram != nil
      button.setAccessibilityLabel(button.title + " " + input.displayName)
      button.invoke = { [weak content, weak button] in
        guard let button else { return }
        let muted = button.state != .on
        content?.updateAudio(target: target) { $0.audioChannelMuted[id] = muted }
      }
    }
    monitor.state = content.localState.monitorAudioInputDeviceInternalIDs.contains(id) ? .on : .off
    monitor.isEnabled = content.canMonitor
    monitor.invoke = { [weak content, weak monitor] in
      let enabled = monitor?.state == .on
      content?.updateMonitor { state in
        if enabled {
          state.monitorAudioInputDeviceInternalIDs.insert(id)
        } else {
          state.monitorAudioInputDeviceInternalIDs.remove(id)
        }
      }
    }
    let target: WorkspaceCanvasTarget =
      content.uiState.selectedAudioMix == .portrait ? .portrait : .landscape
    let preferences =
      content.selectedProgram.flatMap {
        try? content.preferences(for: $0.internalID, target: target)
      } ?? .init()
    gain.configure(
      label: "",
      value: ProgramPreferences.linearAudioChannelGain(
        fromDecibels: Double(preferences.audioChannelGainsDecibelTenths[id] ?? 0) / 10),
      isEnabled: content.selectedProgram != nil, peakProvider: { peakMeter.peak(for: "v4-\(id)") },
      onPreview: { [weak content] value in
        let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: value)
        content?.updateAudio(target: target) {
          $0.audioChannelGainsDecibelTenths[id] = Int32((decibels * 10).rounded())
        }
      }, onCommit: { _ in })
    gain.setAccessibilityLabel(
      (content.uiState.selectedAudioMix == .landscape ? "Landscape " : "Portrait ")
        + input.displayName + " Gain")
  }
  func stop() {
    gain.configure(label: "", value: 1, peakProvider: nil, onPreview: { _ in }, onCommit: { _ in })
  }
}
