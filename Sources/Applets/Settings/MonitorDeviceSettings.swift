// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation
import LDTXProgramRuntime
import Observation
import SwiftUI

struct MonitorOutputDevice: Identifiable, Equatable {
  let id: String
  let name: String
}

@MainActor
@Observable
final class MonitorDeviceSettingsModel {
  private(set) var devices: [MonitorOutputDevice] = []
  private(set) var currentUID: String
  private(set) var discoveryFailed = false
  @ObservationIgnored var reportError: (Error) -> Void = { _ in }
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let deviceProvider: () throws -> [MonitorOutputDevice]
  @ObservationIgnored private var lastFailure: String?
  @ObservationIgnored private var observation: MonitorDeviceObservation?

  init(
    defaults: UserDefaults = .standard,
    observesChanges: Bool = true,
    deviceProvider: @escaping () throws -> [MonitorOutputDevice] = {
      try AudioHardwareSystem.shared.devices.compactMap { device in
        guard try device.outputStreamConfiguration.contains(where: { $0.mNumberChannels > 0 })
        else { return nil }
        return MonitorOutputDevice(id: try device.uid, name: try device.name)
      }
    }
  ) {
    self.defaults = defaults
    self.deviceProvider = deviceProvider
    currentUID = defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) ?? ""
    if observesChanges {
      observation = MonitorDeviceObservation { [weak self] in
        Task { @MainActor [weak self] in self?.refresh() }
      }
    }
  }

  var currentName: String {
    if currentUID.isEmpty { return "System Default" }
    return devices.first { $0.id == currentUID }?.name ?? "Unavailable: \(currentUID)"
  }
  func refresh() {
    currentUID = defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) ?? ""
    do {
      devices =
        [MonitorOutputDevice(id: "", name: "System Default")]
        + (try deviceProvider()).filter { !$0.id.isEmpty }.sorted {
          let order = $0.name.localizedStandardCompare($1.name)
          return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
      discoveryFailed = false
      lastFailure = nil
    } catch {
      devices = []
      discoveryFailed = true
      let failure = error.localizedDescription
      if lastFailure != failure {
        lastFailure = failure
        reportError(error)
      }
    }
  }
  func select(_ uid: String) {
    refresh()
    guard !discoveryFailed, devices.contains(where: { $0.id == uid }) else { return }
    defaults.set(uid, forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
    currentUID = uid
  }
}

private final class MonitorDeviceObservation: @unchecked Sendable {
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.settings.monitor-devices")
  private let listener: AudioObjectPropertyListenerBlock
  private var defaultsObserver: NSObjectProtocol?
  private let registered: Bool

  init(onChange: @escaping @Sendable () -> Void) {
    listener = { _, _ in onChange() }
    registered =
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: nil
    ) { _ in onChange() }
  }
  deinit {
    if registered {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
  }
}

struct MonitorDeviceSettingsView: View {
  @Bindable var model: MonitorDeviceSettingsModel

  var body: some View {
    Form {
      Section("Monitor Output") {
        LabeledContent("Current Device", value: model.currentName)
        List(
          model.devices,
          selection: Binding<String?>(
            get: { nil }, set: { if let uid = $0 { model.select(uid) } })
        ) { device in
          Text(device.name).tag(device.id)
        }
        .frame(minHeight: 120)
        Button("Refresh", action: model.refresh)
      }
    }
    .formStyle(.grouped)
    .onAppear { model.refresh() }
  }
}
