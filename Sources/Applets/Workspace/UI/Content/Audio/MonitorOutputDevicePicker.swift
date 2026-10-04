// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import LDTXWorkspaceAppletInterface
import SwiftUI

struct MonitorOutputDevicePicker: View {
  @AppStorage(WorkspaceAudioEngine.outputDevicePreferenceKey)
  private var deviceUID = ""
  @State private var devices: [(uid: String, name: String)] = []
  @State private var hasLoaded = false
  @State private var deviceError: String?
  @State private var failures = WorkspaceAudioEngine.failureMessages

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        WorkspaceSelectionField(
          title: "Monitor Device", current: deviceUID.isEmpty ? nil : deviceUID,
          options: devices.map { .init(id: $0.uid, name: $0.name) },
          loaded: hasLoaded, loadError: deviceError, emptyLabel: "System Default",
          clearTitle: "Use System Default", refresh: refreshDevices,
          commit: { selected in
            if selected != nil {
              refreshDevices()
              if let deviceError { throw WorkspaceSelectionError(message: deviceError) }
            }
            guard selected == nil || devices.contains(where: { $0.uid == selected }) else {
              throw WorkspaceSelectionError(message: "The selected monitor device is unavailable.")
            }
            deviceUID = selected ?? ""
          })
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
    defer { hasLoaded = true }
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
