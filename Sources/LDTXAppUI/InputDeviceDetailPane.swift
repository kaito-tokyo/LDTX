// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

public struct InputDeviceDetailPane: View {
    @Binding private var inputDevices: [WorkspaceInputDeviceRecord]
    @Binding private var selectedInputDeviceID: String?
    private var cameras: [InputPhysicalDeviceOption]
    private var audioDevices: [InputPhysicalDeviceOption]
    private var deleteInputDevice: (String) -> Void

    public init(
        inputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        selectedInputDeviceID: Binding<String?>,
        cameras: [InputPhysicalDeviceOption],
        audioDevices: [InputPhysicalDeviceOption],
        deleteInputDevice: @escaping (String) -> Void
    ) {
        _inputDevices = inputDevices
        _selectedInputDeviceID = selectedInputDeviceID
        self.cameras = cameras
        self.audioDevices = audioDevices
        self.deleteInputDevice = deleteInputDevice
    }

    public var body: some View {
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
                }

                physicalDeviceSection(for: inputDevice)

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
    private func physicalDeviceSection(
        for inputDevice: Binding<WorkspaceInputDeviceRecord>
    ) -> some View {
        switch inputDevice.wrappedValue.kind {
        case .video:
            Section("Physical Device") {
                VStack(spacing: 0) {
                    physicalDeviceSelectionRow(
                        title: "No camera",
                        subtitle: nil,
                        systemImage: "video.slash",
                        isSelected: inputDevice.wrappedValue.physicalDeviceID == nil,
                        accessibilityIdentifier: "workspaceNoCameraDeviceRow"
                    ) {
                        inputDevice.wrappedValue.physicalDeviceID = nil
                    }

                    ForEach(cameras) { camera in
                        Divider()
                        physicalDeviceSelectionRow(
                            title: camera.name,
                            subtitle: inputCameraDeviceSource(camera),
                            systemImage: "video",
                            isSelected: inputDevice.wrappedValue.physicalDeviceID == camera.id,
                            accessibilityIdentifier: "workspaceInputCameraDeviceRow-\(camera.id)"
                        ) {
                            inputDevice.wrappedValue.physicalDeviceID = camera.id
                        }
                    }
                }
            }
        case .audio:
            Section("Physical Device") {
                VStack(spacing: 0) {
                    physicalDeviceSelectionRow(
                        title: "No audio",
                        subtitle: nil,
                        systemImage: "speaker.slash",
                        isSelected: inputDevice.wrappedValue.physicalDeviceID == nil,
                        accessibilityIdentifier: "workspaceNoAudioDeviceRow"
                    ) {
                        inputDevice.wrappedValue.physicalDeviceID = nil
                    }

                    ForEach(audioDevices) { device in
                        Divider()
                        physicalDeviceSelectionRow(
                            title: device.name,
                            subtitle: inputAudioDeviceSource(device),
                            systemImage: "waveform",
                            isSelected: inputDevice.wrappedValue.physicalDeviceID == device.id,
                            accessibilityIdentifier: "workspaceInputAudioDeviceRow-\(device.id)"
                        ) {
                            inputDevice.wrappedValue.physicalDeviceID = device.id
                        }
                    }
                }
            }
        case .unspecified:
            EmptyView()
        }
    }

    private func physicalDeviceSelectionRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        isSelected: Bool,
        accessibilityIdentifier: String,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func inputCameraDeviceSource(_ camera: InputPhysicalDeviceOption) -> String {
        camera.isExternal ? "USB Camera" : "Camera"
    }

    private func inputAudioDeviceSource(_ device: InputPhysicalDeviceOption) -> String {
        device.isExternal ? "USB Audio" : "Audio"
    }
}

#Preview("Video Input Device") {
    @Previewable @State var inputDevices: [WorkspaceInputDeviceRecord] = [
        WorkspaceInputDeviceRecord(
            id: "input-1",
            name: "Input 1",
            kind: .video,
            physicalDeviceID: "camera-1"
        )
    ]
    @Previewable @State var selectedInputDeviceID: String? = "input-1"

    InputDeviceDetailPane(
        inputDevices: $inputDevices,
        selectedInputDeviceID: $selectedInputDeviceID,
        cameras: [
            InputPhysicalDeviceOption(id: "camera-1", name: "Studio Display Camera", isExternal: false),
            InputPhysicalDeviceOption(id: "camera-2", name: "USB Capture HDMI", isExternal: true),
        ],
        audioDevices: [
            InputPhysicalDeviceOption(id: "audio-1", name: "USB Audio", isExternal: true),
        ],
        deleteInputDevice: { _ in }
    )
    .frame(width: 420, height: 360)
}
