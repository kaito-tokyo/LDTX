import AppKit
import LDTXProgram
import LDTXProgramRuntime
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import LDTXProtos
import LDTXWorkspaceAppletModel

final class MasterVolumeEditor: NSViewController {
  private let storeService: WorkspaceStoreService

  init(storeService: WorkspaceStoreService) {
    self.storeService = storeService
    super.init(nibName: nil, bundle: nil)
    for field in masterFields {
      field.onEditsChanged = { [weak storeService] in storeService?.refreshUnconfirmedChanges() }
    }
    storeService.registerContentEditValidator(
      hasChanges: { [weak self] in self?.masterFields.contains { $0.dirty } ?? false },
      submit: { [weak self] in
        for field in self?.masterFields ?? [] { try field.submit() }
      }
    ) { [weak self] in
      for field in self?.masterFields ?? [] {
        if field.dirty { _ = try field.validatedValue() }
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private let masters = [AudioChannelControlView(), AudioChannelControlView()]
  private(set) var masterFields = [AudioDecibelField(), AudioDecibelField()]
  private let monitorVolume = NSSlider(
    value: 0, minValue: ProgramPreferences.minimumAudioChannelGainDecibels,
    maxValue: ProgramPreferences.maximumAudioChannelGainDecibels, target: nil, action: nil)
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
    let peakMeter = storeService.audioPeakMeter
    _ = view
    let id = storeService.selectedProgram?.internalID
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
        id.flatMap { try? storeService.preferences(for: $0, target: target) } ?? .init()
      let value =
        (preferences.hasAudioMasterVolumeDecibels
          ? preferences.audioMasterVolumeDecibels.double : 0)
      masters[index].configure(
        label: "", value: ProgramPreferences.linearAudioChannelGain(fromDecibels: value),
        showsValue: false, isEnabled: enabled,
        peakProvider: { peakMeter.peak(for: index == 0 ? .landscape : .portrait) },
        onPreview: { [weak storeService] gain in
          let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: gain)
          guard let value = try? Rational32DecibelEncoding.encode(decibels) else {
            return
          }
          storeService?.updateAudio(target: target) {
            $0.audioMasterVolumeDecibels = value
          }
        }, onCommit: { _ in })
      masterFields[index].configure(
        value: preferences.hasAudioMasterVolumeDecibels
          ? preferences.audioMasterVolumeDecibels : .with { $0.set(num: 0, den: 10) },
        enabled: enabled
      ) { [weak storeService] value in
        storeService?.updateAudio(target: target) {
          $0.audioMasterVolumeDecibels = value
        } ?? false
      }
      masterFields[index].onInvalid = { [weak storeService] message in
        storeService?.reportInputValidationError(WorkspaceSelectionError(message: message))
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
  private(set) var dirty = false {
    didSet { if oldValue != dirty { onEditsChanged() } }
  }
  private var submittedText = ""
  var onEditsChanged: () -> Void = {}
  private var editing = false
  private var commitValue: (Ldtx_Workspace_V4_Rational32) -> Bool = { _ in false }
  var onInvalid: (String) -> Void = { _ in }
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
      submittedText = stringValue
    }
  }
  func discard() {
    dirty = false
    editing = false
  }
  func controlTextDidBeginEditing(_ notification: Notification) { editing = true }
  func controlTextDidChange(_ notification: Notification) { dirty = stringValue != submittedText }
  func controlTextDidEndEditing(_ notification: Notification) {
    editing = false
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
    commit()
    return true
  }
  func commit() {
    guard dirty else { return }
    do { try submit() } catch {
      toolTip = error.localizedDescription
      onInvalid(error.localizedDescription)
    }
  }
  func submit() throws {
    guard dirty else { return }
    let value = try validatedValue()
    guard commitValue(value) else {
      throw WorkspaceSelectionError(message: "The master volume could not be applied.")
    }
    submittedText = stringValue
    dirty = false
    toolTip = nil
  }
  func validatedValue() throws -> Ldtx_Workspace_V4_Rational32 {
    guard let parsed = try? RationalParseStrategy().parse(stringValue),
      let value = try? Rational32DecibelEncoding.encode(parsed.double),
      (ProgramPreferences
        .minimumAudioChannelGainDecibels...ProgramPreferences.maximumAudioChannelGainDecibels)
        .contains(value.double)
    else {
      throw WorkspaceSelectionError(message: "Invalid volume.")
    }
    return value
  }
}
