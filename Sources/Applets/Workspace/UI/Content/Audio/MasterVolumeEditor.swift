import AppKit
import LDTXProgram
import LDTXProgramRuntime
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import LDTXProtos
import LDTXWorkspaceAppletModel

final class MasterVolumeEditor: NSViewController {
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

  private let masters = [AudioChannelControlView(), AudioChannelControlView()]
  private(set) var masterFields = [AudioDecibelField(), AudioDecibelField()]
  private let monitorVolume = NSSlider(
    value: 0, minValue: ProgramPreferences.minimumAudioChannelGainDecibels,
    maxValue: ProgramPreferences.maximumAudioChannelGainDecibels, target: nil, action: nil)
  private var programID: Int64?

  override func loadView() {
    view = NSView()
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 114 + 20 + 24).isActive = true
    let masterRows = (0..<2).map { index -> [NSView] in
      let name = index == 0 ? "Landscape" : "Portrait"
      let icon = NSImageView(
        image: NSImage(
          systemSymbolName: index == 0 ? "rectangle" : "rectangle.portrait",
          accessibilityDescription: name)!)
      icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
      icon.imageScaling = .scaleProportionallyDown
      icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
      icon.setAccessibilityLabel(name + " Volume")
      masterFields[index].widthAnchor.constraint(equalToConstant: 50).isActive = true
      return [icon, masters[index], masterFields[index], NSTextField(labelWithString: "dB")]
    }
    let grid = NSGridView(views: masterRows)
    grid.yPlacement = .center
    grid.rowAlignment = .none
    grid.columnSpacing = 8
    grid.rowSpacing = 12
    grid.column(at: 0).width = 20
    grid.column(at: 2).width = 50
    grid.column(at: 3).width = 20
    for master in masters {
      master.widthAnchor.constraint(equalTo: grid.widthAnchor, constant: -114).isActive = true
    }
    monitorVolume.target = self
    monitorVolume.action = #selector(monitorChanged)
    monitorVolume.isContinuous = true
    let heading = NSTextField(labelWithString: "Master Volumes")
    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let separator = NSBox()
    separator.boxType = .separator
    let monitorRow = contentStack(
      [NSTextField(labelWithString: "Monitor Volume"), monitorVolume], vertical: false)
    let stack = contentStack([heading, grid, monitorRow, separator])
    pinContent(stack, in: view)
    for child in [grid, monitorRow, separator] {
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    refresh()
  }

  override func viewWillLayout() {
    super.viewWillLayout()
    refresh()
  }

  func refresh() {
    _ = view
    let id = appletData.selectedProgram(
      in: stateService.workspaceDefinition, for: stateService.localStateURL)?.internalID
    if programID != id {
      for field in masterFields {
        field.discard()
      }
      view.window?.makeFirstResponder(nil)
      programID = id
    }
    let enabled = id != nil
    for (index, target) in [WorkspaceCanvasTarget.landscape, .portrait].enumerated() {
      let preferences =
        id.flatMap { stateService.workspacePreferences[keyPath: target.preferences][$0] } ?? .init()
      let value =
        (preferences.hasAudioMasterVolumeDecibels
          ? preferences.audioMasterVolumeDecibels.double : 0)
      masters[index].configure(
        label: "", value: ProgramPreferences.linearAudioChannelGain(fromDecibels: value),
        showsValue: false, isEnabled: enabled,
        peakProvider: { [peakMeter] in peakMeter.peak(for: index == 0 ? .landscape : .portrait) },
        onPreview: { [weak stateService] gain in
          let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: gain)
          guard let value = try? Rational32DecibelEncoding.encode(decibels) else {
            return
          }
          guard let stateService, let id,
            stateService.workspaceDefinition.programs.contains(where: { $0.internalID == id })
          else { return }
          stateService.workspacePreferences[keyPath: target.preferences][id, default: .init()]
            .audioMasterVolumeDecibels = value
        }, onCommit: { _ in })
      masterFields[index].configure(
        value: preferences.hasAudioMasterVolumeDecibels
          ? preferences.audioMasterVolumeDecibels : .with { $0.set(num: 0, den: 10) },
        enabled: enabled
      ) { [weak stateService] value in
        guard let stateService, let id,
          stateService.workspaceDefinition.programs.contains(where: { $0.internalID == id })
        else { return false }
        stateService.workspacePreferences[keyPath: target.preferences][id, default: .init()]
          .audioMasterVolumeDecibels = value
        return true
      }
    }
    monitorVolume.doubleValue =
      stateService.localStateURL.map { appletData.state(for: $0) }.flatMap(\.monitorVolume) ?? 0
    monitorVolume.isEnabled = stateService.localStateURL != nil
  }
  @discardableResult
  func setMonitorVolume(_ value: Double) -> Bool {
    guard let url = stateService.localStateURL else { return false }
    do {
      let volume = try Rational32DecibelEncoding.encode(value).double
      appletData.updateState(for: url) { $0.monitorVolume = volume }
      runtimeActions()?.synchronizeAudioMonitor()
      return true
    } catch {
      reportError(error)
      return false
    }
  }

  @objc private func monitorChanged() {
    setMonitorVolume(monitorVolume.doubleValue)
  }

}

final class AudioDecibelField: NSTextField, NSTextFieldDelegate {
  private(set) var dirty = false
  private var modelText = ""
  private var editing = false
  private var commitValue: (Ldtx_Workspace_V4_Rational32) -> Bool = { _ in false }
  init() {
    super.init(frame: .zero)
    delegate = self
    setAccessibilityLabel("Master volume in dB")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func configure(
    value: Ldtx_Workspace_V4_Rational32, enabled: Bool,
    commit: @escaping (Ldtx_Workspace_V4_Rational32) -> Bool
  ) {
    isEnabled = enabled
    commitValue = commit
    if !dirty && !editing {
      stringValue = RationalFormatStyle().format(value)
      modelText = stringValue
    }
  }
  func discard() {
    dirty = false
    editing = false
  }
  func controlTextDidBeginEditing(_ notification: Notification) { editing = true }
  func controlTextDidChange(_ notification: Notification) {
    dirty = stringValue != modelText
    if let value = try? RationalParseStrategy().parse(stringValue),
      (-80...20).contains(value.double),
      let encoded = try? Rational32DecibelEncoding.encode(value.double), commitValue(encoded)
    {
      modelText = stringValue
      dirty = false
    }
  }
  func controlTextDidEndEditing(_ notification: Notification) {
    editing = false
  }
}
