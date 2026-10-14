import AppKit
import LDTXProgram
import LDTXProgramRuntime
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import LDTXProtos
import LDTXWorkspaceAppletModel

final class AudioMixEditor: NSViewController {
  private let peakMeter: ProgramAudioPeakMeter
  private let reportError: (Error) -> Void
  private let appletData: WorkspaceAppletData
  private let stateService: WorkspaceStateService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?

  init(
    stateService: WorkspaceStateService, appletData: WorkspaceAppletData,
    peakMeter: ProgramAudioPeakMeter, reportError: @escaping (Error) -> Void,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.reportError = reportError
    self.peakMeter = peakMeter
    self.appletData = appletData
    self.runtimeActions = runtimeActions
    self.stateService = stateService
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  let outputErrorLabel = NSTextField(wrappingLabelWithString: "")
  private let channels = contentStack([])
  private var rows: [Int64: AudioInputRow] = [:]

  override func loadView() {
    view = NSView()
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
      outputErrorLabel, bottomSeparator,
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

  @discardableResult
  func setAudioChannelGain(_ decibels: Double, forAudioInputDeviceInternalID id: Int64)
    -> Bool
  {
    guard stateService.workspaceDefinition.audioDevices.contains(where: { $0.internalID == id })
    else {
      reportError(
        WorkspaceSelectionError(message: "The audio device is no longer available."))
      return false
    }
    do {
      stateService.workspacePreferences.audioChannelGainsDecibels[id] =
        try Rational32DecibelEncoding.encode(
          decibels)
    } catch {
      reportError(error)
      return false
    }
    return true
  }

  func refresh() {
    _ = view
    outputErrorLabel.stringValue = stateService.outputFailureMessage ?? ""
    outputErrorLabel.isHidden = stateService.outputFailureMessage == nil
    let inputs = stateService.workspaceDefinition.audioDevices
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
      row.configure(
        input: input, stateService: stateService, appletData: appletData, peakMeter: peakMeter,
        runtimeActions: runtimeActions
      ) {
        [weak self] decibels in
        self?.setAudioChannelGain(decibels, forAudioInputDeviceInternalID: input.internalID)
          ?? false
      }
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
    input: Ldtx_Workspace_V4_AudioInputDevice, stateService: WorkspaceStateService,
    appletData: WorkspaceAppletData, peakMeter: ProgramAudioPeakMeter,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)?,
    setGain: @escaping (Double) -> Bool
  ) {
    let id = input.internalID
    name.stringValue = input.displayName
    for (target, button) in [(WorkspaceCanvasTarget.landscape, landscape), (.portrait, portrait)] {
      let preferences =
        appletData.selectedProgram(
          in: stateService.workspaceDefinition, for: stateService.localStateURL
        ).flatMap {
          stateService.workspacePreferences[keyPath: target.preferences][$0.internalID]
        } ?? .init()
      button.state = preferences.audioChannelMuted[id] == true ? .off : .on
      button.isEnabled =
        appletData.selectedProgram(
          in: stateService.workspaceDefinition, for: stateService.localStateURL) != nil
      button.setAccessibilityLabel(button.title + " " + input.displayName)
      button.invoke = { [weak stateService, weak appletData, weak button] in
        guard let button, let stateService, let appletData,
          let programID = appletData.selectedProgram(
            in: stateService.workspaceDefinition, for: stateService.localStateURL)?.internalID
        else { return }
        stateService.workspacePreferences[keyPath: target.preferences][programID, default: .init()]
          .audioChannelMuted[id] = button.state != .on
      }
    }
    monitor.state =
      (stateService.localStateURL.map { appletData.state(for: $0) }.map {
        $0.monitorAudioInputDeviceInternalIDs.contains(id)
      } ?? false) ? .on : .off
    monitor.isEnabled = stateService.localStateURL != nil
    monitor.invoke = { [weak stateService, weak appletData, weak monitor] in
      guard let stateService, let appletData, let url = stateService.localStateURL else { return }
      let enabled = monitor?.state == .on
      appletData.updateState(for: url) { state in
        if enabled {
          state.monitorAudioInputDeviceInternalIDs.insert(id)
        } else {
          state.monitorAudioInputDeviceInternalIDs.remove(id)
        }
      }
      runtimeActions()?.synchronizeAudioMonitor()
    }
    gain.configure(
      label: "",
      value: ProgramPreferences.linearAudioChannelGain(
        fromDecibels: (stateService.workspacePreferences.audioChannelGainsDecibels[id]?.double ?? 0)
      ),
      isEnabled: true,
      peakProvider: { peakMeter.peak(for: "v4-\(id)") },
      onPreview: { value in
        let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: value)
        _ = setGain(decibels)
      }, onCommit: { _ in })
    gain.setAccessibilityLabel(input.displayName + " Gain")
  }
}
