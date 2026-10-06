// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXWorkspaceAppletInterface

final class AudioMixEditor: NSViewController {
  private let storeService: WorkspaceStoreService

  init(storeService: WorkspaceStoreService) {
    self.storeService = storeService
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  let errorLabel = NSTextField(labelWithString: "")
  let outputErrorLabel = NSTextField(wrappingLabelWithString: "")
  private let channels = contentStack([])
  private var rows: [UInt64: AudioInputRow] = [:]

  override func loadView() {
    view = NSView()
    errorLabel.textColor = .systemRed
    outputErrorLabel.textColor = .systemRed
    func heading(_ title: String) -> NSTextField {
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      return label
    }
    func divider() -> NSBox {
      let box = NSBox()
      box.boxType = .separator
      return box
    }
    let bottomSeparator = divider()
    let stack = contentStack([
      heading("Audio Mix"), channels,
      errorLabel, outputErrorLabel, bottomSeparator,
    ])
    pinContent(stack, in: view)
    for child in [channels, bottomSeparator] {
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    refresh()
  }

  override func viewWillLayout() {
    super.viewWillLayout()
    refresh()
  }

  func refresh() {
    let peakMeter = storeService.audioPeakMeter
    _ = view
    errorLabel.stringValue = storeService.editorFailureMessage ?? ""
    outputErrorLabel.stringValue = storeService.outputFailureMessage ?? ""
    outputErrorLabel.isHidden = storeService.outputFailureMessage == nil
    let inputs = storeService.definition.audioDevices
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
      row.configure(input: input, storeService: storeService, peakMeter: peakMeter)
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
    heading.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    addArrangedSubview(gain)
    gain.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func configure(
    input: Ldtx_Workspace_V4_AudioInputDevice, storeService: WorkspaceStoreService,
    peakMeter: ProgramAudioPeakMeter
  ) {
    let id = input.internalID
    name.stringValue = input.displayName
    for (target, button) in [(WorkspaceCanvasTarget.landscape, landscape), (.portrait, portrait)] {
      let preferences =
        storeService.selectedProgram.flatMap {
          try? storeService.preferences(for: $0.internalID, target: target)
        } ?? .init()
      button.state = preferences.audioChannelMuted[id] == true ? .off : .on
      button.isEnabled = storeService.selectedProgram != nil
      button.setAccessibilityLabel(button.title + " " + input.displayName)
      button.invoke = { [weak storeService, weak button] in
        guard let button else { return }
        let muted = button.state != .on
        storeService?.updateAudio(target: target) { $0.audioChannelMuted[id] = muted }
      }
    }
    monitor.state =
      storeService.localState.monitorAudioInputDeviceInternalIDs.contains(id) ? .on : .off
    monitor.isEnabled = storeService.canMonitor
    monitor.invoke = { [weak storeService, weak monitor] in
      let enabled = monitor?.state == .on
      storeService?.updateMonitor { state in
        if enabled {
          state.monitorAudioInputDeviceInternalIDs.insert(id)
        } else {
          state.monitorAudioInputDeviceInternalIDs.remove(id)
        }
      }
    }
    gain.configure(
      label: "",
      value: ProgramPreferences.linearAudioChannelGain(
        fromDecibels: Double(storeService.preferences.audioChannelGainsDecibelTenths[id] ?? 0) / 10),
      isEnabled: true,
      peakProvider: { peakMeter.peak(for: "v4-\(id)") },
      onPreview: { [weak storeService] value in
        let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: value)
        storeService?.setAudioChannelGain(decibels, forAudioInputDeviceInternalID: id)
      }, onCommit: { _ in })
    gain.setAccessibilityLabel(input.displayName + " Gain")
  }
}
