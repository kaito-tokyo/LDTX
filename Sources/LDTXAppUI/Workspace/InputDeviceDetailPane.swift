// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

public struct InputDeviceDetailPane: View {
    @Binding private var inputDevices: [WorkspaceInputDeviceRecord]
    @Binding private var selectedInputDeviceID: String?
    private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    private var cameras: [InputPhysicalDeviceOption]
    private var audioDevices: [InputPhysicalDeviceOption]
    private var refreshPhysicalDevices: () -> Void
    private var deleteInputDevice: (String) -> Void

    public init(
        inputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        selectedInputDeviceID: Binding<String?>,
        workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        cameras: [InputPhysicalDeviceOption],
        audioDevices: [InputPhysicalDeviceOption],
        refreshPhysicalDevices: @escaping () -> Void,
        deleteInputDevice: @escaping (String) -> Void
    ) {
        _inputDevices = inputDevices
        _selectedInputDeviceID = selectedInputDeviceID
        self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
        self.cameras = cameras
        self.audioDevices = audioDevices
        self.refreshPhysicalDevices = refreshPhysicalDevices
        self.deleteInputDevice = deleteInputDevice
    }

    public var body: some View {
        Form {
            if let selectedInputDeviceIndex {
                let inputDevice = inputDevices[selectedInputDeviceIndex]
                Section("Input Device") {
                    Picker("Kind", selection: kindBinding(for: selectedInputDeviceIndex)) {
                        Text("Video").tag(WorkspaceInputDeviceKind.video)
                        Text("Audio").tag(WorkspaceInputDeviceKind.audio)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("workspaceInputDeviceKindPicker")
                }

                physicalDeviceSection(for: selectedInputDeviceIndex)
                previewSection(for: inputDevice)

                Section {
                    Button(role: .destructive) {
                        let id = inputDevice.id
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

    private var selectedInputDeviceIndex: Int? {
        guard let selectedInputDeviceID,
              let index = inputDevices.firstIndex(where: { $0.id == selectedInputDeviceID }) else {
            return nil
        }
        return index
    }

    private func kindBinding(
        for index: Int
    ) -> Binding<WorkspaceInputDeviceKind> {
        Binding(
            get: { inputDevices[index].kind },
            set: { newValue in
                var updated = inputDevices[index]
                updated.kind = newValue
                updated.physicalDeviceID = nil
                replaceInputDevice(at: index, with: updated)
            }
        )
    }

    @ViewBuilder
    private func physicalDeviceSection(
        for index: Int
    ) -> some View {
        let inputDevice = inputDevices[index]
        switch inputDevice.kind {
        case .video:
            Section {
                refreshPhysicalDevicesButton
                VStack(spacing: 0) {
                    physicalDeviceSelectionRow(
                        title: "No camera",
                        subtitle: nil,
                        systemImage: "video.slash",
                        isSelected: inputDevice.physicalDeviceID == nil,
                        accessibilityIdentifier: "workspaceNoCameraDeviceRow"
                    ) {
                        updatePhysicalDeviceSelection(for: index, physicalDeviceID: nil)
                    }

                    ForEach(cameras) { camera in
                        Divider()
                        physicalDeviceSelectionRow(
                            title: camera.name,
                            subtitle: inputCameraDeviceSource(camera),
                            systemImage: "video",
                            isSelected: inputDevice.physicalDeviceID == camera.id,
                            accessibilityIdentifier: "workspaceInputCameraDeviceRow-\(camera.id)"
                        ) {
                            updatePhysicalDeviceSelection(for: index, physicalDeviceID: camera.id)
                        }
                    }
                }
            } header: {
                Text("Physical Device")
            }
        case .audio:
            Section {
                refreshPhysicalDevicesButton
                VStack(spacing: 0) {
                    physicalDeviceSelectionRow(
                        title: "No audio",
                        subtitle: nil,
                        systemImage: "speaker.slash",
                        isSelected: inputDevice.physicalDeviceID == nil,
                        accessibilityIdentifier: "workspaceNoAudioDeviceRow"
                    ) {
                        updatePhysicalDeviceSelection(for: index, physicalDeviceID: nil)
                    }

                    ForEach(audioDevices) { device in
                        Divider()
                        physicalDeviceSelectionRow(
                            title: device.name,
                            subtitle: inputAudioDeviceSource(device),
                            systemImage: "waveform",
                            isSelected: inputDevice.physicalDeviceID == device.id,
                            accessibilityIdentifier: "workspaceInputAudioDeviceRow-\(device.id)"
                        ) {
                            updatePhysicalDeviceSelection(for: index, physicalDeviceID: device.id)
                        }
                    }
                }
            } header: {
                Text("Physical Device")
            }
        case .unspecified:
            EmptyView()
        }
    }

    @ViewBuilder
    private func previewSection(
        for inputDevice: WorkspaceInputDeviceRecord
    ) -> some View {
        Section("Preview") {
            switch inputDevice.kind {
            case .video:
                if inputDevice.physicalDeviceID == nil {
                    ContentUnavailableView(
                        "No Camera Selected",
                        systemImage: "video.slash",
                        description: Text("Choose a physical camera to show a live preview here.")
                    )
                } else {
                    ProgramPreviewPane(
                        title: "\(inputDevice.name) Preview",
                        outputCanvas: inputPreviewOutputCanvas,
                        outputDestination: inputPreviewOutputDestination,
                        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                        selectedProgramDefinitionRecord: nil,
                        compositeProgramDefinition: inputPreviewComposite(for: inputDevice),
                        workspaceInputDevices: inputDevices,
                        inputCameraDeviceMappings: [:]
                    )
                }
            case .audio:
                AudioInputSpectrogramPane(audioDeviceID: inputDevice.physicalDeviceID)
            case .unspecified:
                EmptyView()
            }
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

    private var refreshPhysicalDevicesButton: some View {
        Button {
            refreshPhysicalDevices()
        } label: {
            Label("Refresh Device List", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("refreshInputDeviceListButton")
    }

    private func inputCameraDeviceSource(_ camera: InputPhysicalDeviceOption) -> String {
        camera.isExternal ? "USB Camera" : "Camera"
    }

    private func inputAudioDeviceSource(_ device: InputPhysicalDeviceOption) -> String {
        device.isExternal ? "USB Audio" : "Audio"
    }

    private var inputPreviewOutputCanvas: OutputCanvasModel {
        OutputCanvasModel(
            programDefinitionFrameRate: 30,
            programVideoPTSInputKey: inputPreviewInputKey,
            programAudioPTSInputKey: nil
        )
    }

    private var inputPreviewOutputDestination: OutputDestinationModel {
        OutputDestinationModel(
            selectedResolution: .p720,
            selectedFrameRate: .fps30
        )
    }

    private var inputPreviewInputKey: String {
        "Input Preview"
    }

    private func inputPreviewComposite(
        for inputDevice: WorkspaceInputDeviceRecord
    ) -> CompositeProgramDefinition {
        CompositeProgramDefinition(
            steps: [
                CompositeProgramStep(
                    name: inputPreviewInputKey,
                    component: .inputCameraDevice(
                        InputDeviceComponent(
                            inputDeviceID: inputDevice.id,
                            sourceCropTop: 0,
                            sourceCropRight: 0,
                            destinationX: 0,
                            destinationY: 0,
                            destinationScale: 1,
                            removesBackground: false
                        )
                    )
                )
            ],
            programVideoPTSInputKey: inputPreviewInputKey
        )
    }

    private func updatePhysicalDeviceSelection(
        for index: Int,
        physicalDeviceID: String?
    ) {
        var updated = inputDevices[index]
        updated.physicalDeviceID = physicalDeviceID
        replaceInputDevice(at: index, with: updated)
    }

    private func replaceInputDevice(
        at index: Int,
        with inputDevice: WorkspaceInputDeviceRecord
    ) {
        var updatedInputDevices = inputDevices
        updatedInputDevices[index] = inputDevice
        inputDevices = updatedInputDevices
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
        workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
        cameras: [
            InputPhysicalDeviceOption(id: "camera-1", name: "Studio Display Camera", isExternal: false),
            InputPhysicalDeviceOption(id: "camera-2", name: "USB Capture HDMI", isExternal: true),
        ],
        audioDevices: [
            InputPhysicalDeviceOption(id: "audio-1", name: "USB Audio", isExternal: true),
        ],
        refreshPhysicalDevices: {},
        deleteInputDevice: { _ in }
    )
    .frame(width: 420, height: 360)
}
