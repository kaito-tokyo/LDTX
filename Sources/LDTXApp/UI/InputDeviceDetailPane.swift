// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCapture
import LDTXWorkspace
import SwiftUI

struct InputDeviceDetailPane: View {
    @Binding var inputDevices: [WorkspaceInputDeviceRecord]
    @Binding var selectedInputDeviceID: String?
    var cameras: [CameraCaptureSource]
    var audioDevices: [AudioCaptureSource]
    var deleteInputDevice: (String) -> Void

    var body: some View {
        Form {
            if let inputDevice = selectedInputDeviceBinding {
                Section("Input Device") {
                    TextField("Name", text: inputDevice.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("workspaceInputDeviceNameField")

                    Picker("Kind", selection: kindBinding(for: inputDevice)) {
                        Text("Video").tag(WorkspaceInputDeviceKind.video)
                        Text("Audio").tag(WorkspaceInputDeviceKind.audio)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("workspaceInputDeviceKindPicker")

                    physicalDevicePicker(for: inputDevice)
                }

                Section {
                    Button(role: .destructive) {
                        let id = inputDevice.wrappedValue.id
                        deleteInputDevice(id)
                    } label: {
                        Label("Delete Input Device", systemImage: "trash")
                    }
                    .accessibilityIdentifier("deleteWorkspaceInputDeviceButton")
                }
            } else {
                Section("Input Device") {
                    Text("Select an input device in the sidebar.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selectedInputDeviceBinding: Binding<WorkspaceInputDeviceRecord>? {
        guard let selectedInputDeviceID,
              let index = inputDevices.firstIndex(where: { $0.id == selectedInputDeviceID }) else {
            return nil
        }
        return $inputDevices[index]
    }

    private func kindBinding(
        for inputDevice: Binding<WorkspaceInputDeviceRecord>
    ) -> Binding<WorkspaceInputDeviceKind> {
        Binding(
            get: { inputDevice.wrappedValue.kind },
            set: { newValue in
                inputDevice.wrappedValue.kind = newValue
                inputDevice.wrappedValue.physicalDeviceID = nil
            }
        )
    }

    @ViewBuilder
    private func physicalDevicePicker(
        for inputDevice: Binding<WorkspaceInputDeviceRecord>
    ) -> some View {
        switch inputDevice.wrappedValue.kind {
        case .video:
            Picker("Physical Device", selection: physicalDeviceIDBinding(for: inputDevice)) {
                Text("No camera").tag(Optional<String>.none)
                ForEach(cameras) { camera in
                    Text(inputCameraDeviceLabel(camera)).tag(Optional(camera.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("workspaceInputCameraDevicePicker")
        case .audio:
            Picker("Physical Device", selection: physicalDeviceIDBinding(for: inputDevice)) {
                Text("No audio").tag(Optional<String>.none)
                ForEach(audioDevices) { device in
                    Text(inputAudioDeviceLabel(device)).tag(Optional(device.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("workspaceInputAudioDevicePicker")
        case .unspecified:
            EmptyView()
        }
    }

    private func physicalDeviceIDBinding(
        for inputDevice: Binding<WorkspaceInputDeviceRecord>
    ) -> Binding<String?> {
        Binding(
            get: { inputDevice.wrappedValue.physicalDeviceID },
            set: { newValue in
                inputDevice.wrappedValue.physicalDeviceID = newValue?.isEmpty == false ? newValue : nil
            }
        )
    }

    private func inputCameraDeviceLabel(_ camera: CameraCaptureSource) -> String {
        let source = camera.isExternal ? "USB" : "Camera"
        return "\(source): \(camera.name)"
    }

    private func inputAudioDeviceLabel(_ device: AudioCaptureSource) -> String {
        let source = device.isExternal ? "USB" : "Audio"
        return "\(source): \(device.name)"
    }
}
