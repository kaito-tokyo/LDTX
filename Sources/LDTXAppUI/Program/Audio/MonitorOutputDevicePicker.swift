// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import LDTXProgramRuntime
import SwiftUI

struct MonitorOutputDevicePicker: View {
  @AppStorage(WorkspaceAudioEngine.outputDevicePreferenceKey)
  private var deviceUID = ""
  @State private var devices: [(uid: String, name: String)] = []
  @State private var deviceError: String?
  @State private var failures = WorkspaceAudioEngine.failureMessages

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Picker("Monitor Device", selection: $deviceUID) {
          Text("Not selected").tag("")
          ForEach(devices, id: \.uid) { device in
            Text(device.name).tag(device.uid)
          }
          if !deviceUID.isEmpty && !devices.contains(where: { $0.uid == deviceUID }) {
            Text("Selected device unavailable").tag(deviceUID)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Monitor Device")
        .accessibilityIdentifier("monitorOutputDevicePicker")
        Button(action: refreshDevices) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh Monitor Devices")
        .accessibilityLabel("Refresh Monitor Devices")
      }
      ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
        Text(failure).font(.caption).foregroundStyle(.red)
      }
      if let deviceError {
        Text(deviceError).font(.caption).foregroundStyle(.red)
      }
    }
    .onAppear {
      refreshDevices()
      failures = WorkspaceAudioEngine.failureMessages
    }
    .onReceive(
      NotificationCenter.default.publisher(for: WorkspaceAudioEngine.statusDidChange)
        .receive(on: RunLoop.main)
    ) { _ in
      failures = WorkspaceAudioEngine.failureMessages
    }
  }

  private func refreshDevices() {
    do {
      devices = try AudioHardwareSystem.shared.devices.compactMap { device in
        guard try device.outputStreamConfiguration.contains(where: { $0.mNumberChannels > 0 })
        else {
          return nil
        }
        return (try device.uid, try device.name)
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      deviceError = nil
    } catch {
      deviceError = error.localizedDescription
    }
  }
}
