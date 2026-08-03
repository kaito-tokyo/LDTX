// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

public struct InputDeviceDetailPane: View {
  @State private var inputPreviewSettings = AppPreviewSettings()
  @Binding private var inputDevices: [WorkspaceInputDeviceRecord]
  @Binding private var selectedInputDeviceID: String?
  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private var cameras: [InputPhysicalDeviceOption]
  private var audioDevices: [InputPhysicalDeviceOption]
  private var refreshPhysicalDevices: () -> Void
  private var deleteInputDevice: (String) -> Void
  private var previewPlacement: InputDevicePreviewPlacement
  private var showsDeleteSection: Bool
  private var supportsBackgroundRemoval: Bool
  private var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?

  public init(
    inputDevices: Binding<[WorkspaceInputDeviceRecord]>,
    selectedInputDeviceID: Binding<String?>,
    workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    cameras: [InputPhysicalDeviceOption],
    audioDevices: [InputPhysicalDeviceOption],
    refreshPhysicalDevices: @escaping () -> Void,
    deleteInputDevice: @escaping (String) -> Void,
    previewPlacement: InputDevicePreviewPlacement = .afterSettings,
    showsDeleteSection: Bool = true,
    supportsBackgroundRemoval: Bool = true,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil
  ) {
    _inputDevices = inputDevices
    _selectedInputDeviceID = selectedInputDeviceID
    self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    self.cameras = cameras
    self.audioDevices = audioDevices
    self.refreshPhysicalDevices = refreshPhysicalDevices
    self.deleteInputDevice = deleteInputDevice
    self.previewPlacement = previewPlacement
    self.showsDeleteSection = showsDeleteSection
    self.supportsBackgroundRemoval = supportsBackgroundRemoval
    self.backgroundRemovalPreprocessorFactory = backgroundRemovalPreprocessorFactory
  }

  public var body: some View {
    Form {
      if let selectedInputDeviceIndex {
        let inputDevice = inputDevices[selectedInputDeviceIndex]
        if previewPlacement == .beforeSettings {
          previewSection(for: inputDevice)
        }

        physicalDeviceSection(for: selectedInputDeviceIndex)
        overridesSection(for: selectedInputDeviceIndex)
        if previewPlacement == .afterSettings {
          previewSection(for: inputDevice)
        }

        if showsDeleteSection {
          Section {
            Button(role: .destructive) {
              let id = inputDevice.id
              deleteInputDevice(id)
            } label: {
              Label("Delete Input Device", systemImage: "trash")
            }
            .accessibilityIdentifier("deleteWorkspaceInputDeviceButton")
          }
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
}

public enum InputDevicePreviewPlacement: Equatable {
  case beforeSettings
  case afterSettings
  case hidden
}

extension InputDeviceDetailPane {
  fileprivate var selectedInputDeviceIndex: Int? {
    guard let selectedInputDeviceID,
      let index = inputDevices.firstIndex(where: { $0.id == selectedInputDeviceID })
    else {
      return nil
    }
    return index
  }

  @ViewBuilder
  fileprivate func physicalDeviceSection(
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
  fileprivate func overridesSection(
    for index: Int
  ) -> some View {
    let inputDevice = inputDevices[index]
    if inputDevice.kind == .video {
      let overridesEnabled = inputDevice.hasCaptureOverrides
      Section("Overrides") {
        Toggle("Enable Overrides", isOn: captureOverridesEnabledBinding(for: index))
          .accessibilityIdentifier("workspaceInputDeviceOverridesToggle")

        Picker("Color Range", selection: colorRangeOverrideBinding(for: index)) {
          Text("Video Range").tag(WorkspaceInputDeviceColorRangePolicy.videoRange)
          Text("Full Range").tag(WorkspaceInputDeviceColorRangePolicy.fullRange)
        }
        .pickerStyle(.segmented)
        .disabled(!overridesEnabled)
        .accessibilityIdentifier("workspaceInputDeviceColorRangePicker")

        Picker("Resolution", selection: captureResolutionOverrideBinding(for: index)) {
          Text("Canvas").tag(nil as InputDeviceCaptureResolutionOverride?)
          ForEach(captureResolutionOverrideOptions(for: inputDevice)) { option in
            Text(captureResolutionOverrideLabel(option))
              .tag(Optional(option))
          }
        }
        .disabled(!overridesEnabled)
        .accessibilityIdentifier("workspaceInputDeviceResolutionOverridePicker")

        Picker("FPS", selection: captureFrameRateOverrideBinding(for: index)) {
          Text("Canvas").tag(nil as Int?)
          ForEach(captureFrameRateOverrideOptions(for: inputDevice), id: \.self) { frameRate in
            Text("\(frameRate)").tag(Optional(frameRate))
          }
        }
        .disabled(!overridesEnabled)
        .accessibilityIdentifier("workspaceInputDeviceFrameRateOverridePicker")

        Text("Resolution and FPS default to Canvas Settings unless an override is selected.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  fileprivate func previewSection(
    for inputDevice: WorkspaceInputDeviceRecord
  ) -> some View {
    switch previewPlacement {
    case .hidden:
      EmptyView()
    case .beforeSettings, .afterSettings:
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
              previewSettings: $inputPreviewSettings,
              workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
              backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
              lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
              selectedProgramDefinitionRecord: nil,
              compositeProgramDefinition: inputPreviewComposite(for: inputDevice),
              workspaceInputDevices: inputDevices,
              workspaceAudioChannels: [],
              inputCameraDeviceMappings: [:]
            )
          }
        case .audio:
          AudioInputSpectrogramPane(
            audioDeviceID: inputDevice.physicalDeviceID,
            captureSessionCoordinator: workspaceCaptureSessionCoordinator)
        case .unspecified:
          EmptyView()
        }
      }
    }
  }

  fileprivate func physicalDeviceSelectionRow(
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

  fileprivate var refreshPhysicalDevicesButton: some View {
    Button {
      refreshPhysicalDevices()
    } label: {
      Label("Refresh Device List", systemImage: "arrow.clockwise")
    }
    .accessibilityIdentifier("refreshInputDeviceListButton")
  }

  fileprivate func inputCameraDeviceSource(_ camera: InputPhysicalDeviceOption) -> String {
    camera.isExternal ? "USB Camera" : "Camera"
  }

  fileprivate func inputAudioDeviceSource(_ device: InputPhysicalDeviceOption) -> String {
    device.isExternal ? "USB Audio" : "Audio"
  }

  fileprivate var inputPreviewOutputCanvas: OutputCanvasModel {
    OutputCanvasModel(
      canvasSize: OutputCanvasModel.CanvasSize(width: 1_280, height: 720),
      programDefinitionFrameRate: 30
    )
  }

  fileprivate func inputPreviewComposite(
    for inputDevice: WorkspaceInputDeviceRecord
  ) -> CompositeProgramDefinition {
    CompositeProgramDefinition(
      steps: [
        CompositeProgramStep(
          component: .inputCameraDevice(
            InputDeviceComponent(
              inputDeviceID: inputDevice.id,
              sourceCropTop: 0,
              sourceCropRight: 0,
              destinationX: 0,
              destinationY: 0,
              destinationScale: 1
            )
          )
        )
      ]
    )
  }

  fileprivate func updatePhysicalDeviceSelection(
    for index: Int,
    physicalDeviceID: String?
  ) {
    var updated = inputDevices[index]
    updated.physicalDeviceID = physicalDeviceID
    replaceInputDevice(at: index, with: updated)
  }

  fileprivate func replaceInputDevice(
    at index: Int,
    with inputDevice: WorkspaceInputDeviceRecord
  ) {
    var updatedInputDevices = inputDevices
    updatedInputDevices[index] = inputDevice
    inputDevices = updatedInputDevices
  }

  fileprivate func captureOverridesEnabledBinding(
    for index: Int
  ) -> Binding<Bool> {
    Binding(
      get: { inputDevices[index].hasCaptureOverrides },
      set: { isEnabled in
        var updated = inputDevices[index]
        if isEnabled {
          if updated.colorRangePolicy == .unspecified {
            updated.colorRangePolicy = .videoRange
          }
        } else {
          updated.clearCaptureOverrides()
        }
        replaceInputDevice(at: index, with: updated)
      }
    )
  }

  fileprivate func colorRangeOverrideBinding(
    for index: Int
  ) -> Binding<WorkspaceInputDeviceColorRangePolicy> {
    Binding(
      get: {
        let policy = inputDevices[index].colorRangePolicy
        return policy == .unspecified ? .videoRange : policy
      },
      set: { newValue in
        var updated = inputDevices[index]
        updated.colorRangePolicy = newValue
        replaceInputDevice(at: index, with: updated)
      }
    )
  }

  fileprivate func captureResolutionOverrideBinding(
    for index: Int
  ) -> Binding<InputDeviceCaptureResolutionOverride?> {
    Binding(
      get: {
        let inputDevice = inputDevices[index]
        guard let width = inputDevice.captureWidthOverride,
          let height = inputDevice.captureHeightOverride
        else {
          return nil
        }
        return InputDeviceCaptureResolutionOverride(width: width, height: height)
      },
      set: { newValue in
        var updated = inputDevices[index]
        updated.captureWidthOverride = newValue?.width
        updated.captureHeightOverride = newValue?.height
        replaceInputDevice(at: index, with: updated)
      }
    )
  }

  fileprivate func captureFrameRateOverrideBinding(
    for index: Int
  ) -> Binding<Int?> {
    Binding(
      get: { inputDevices[index].captureFrameRateOverride },
      set: { newValue in
        var updated = inputDevices[index]
        updated.captureFrameRateOverride = newValue
        replaceInputDevice(at: index, with: updated)
      }
    )
  }

  fileprivate func captureResolutionOverrideOptions(
    for inputDevice: WorkspaceInputDeviceRecord
  ) -> [InputDeviceCaptureResolutionOverride] {
    var options = OutputCanvasModel.supportedCanvasSizes.map {
      InputDeviceCaptureResolutionOverride(width: $0.width, height: $0.height)
    }
    if let width = inputDevice.captureWidthOverride,
      let height = inputDevice.captureHeightOverride
    {
      let current = InputDeviceCaptureResolutionOverride(width: width, height: height)
      if !options.contains(current) {
        options.append(current)
      }
    }
    return options
  }

  fileprivate func captureResolutionOverrideLabel(
    _ option: InputDeviceCaptureResolutionOverride
  ) -> String {
    "\(option.width)x\(option.height)"
  }

  fileprivate func captureFrameRateOverrideOptions(
    for inputDevice: WorkspaceInputDeviceRecord
  ) -> [Int] {
    var options = [30, 60]
    if let frameRate = inputDevice.captureFrameRateOverride,
      !options.contains(frameRate)
    {
      options.append(frameRate)
      options.sort()
    }
    return options
  }
}

private struct InputDeviceCaptureResolutionOverride: Hashable, Identifiable {
  var width: Int
  var height: Int

  var id: String {
    "\(width)x\(height)"
  }
}
#if DEBUG
  #Preview("Video Input Device") {
    @Previewable @State var inputDevices: [WorkspaceInputDeviceRecord] = [
      WorkspaceInputDeviceRecord(
        id: "input-1",
        name: "Input 1",
        kind: .video,
        physicalDeviceID: "camera-1",
        backgroundRemovalPolicy: .enabled
      )
    ]
    @Previewable @State var selectedInputDeviceID: String? = "input-1"
    let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    InputDeviceDetailPane(
      inputDevices: $inputDevices,
      selectedInputDeviceID: $selectedInputDeviceID,
      workspaceCaptureSessionCoordinator:
        LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      cameras: [
        InputPhysicalDeviceOption(id: "camera-1", name: "Studio Display Camera", isExternal: false),
        InputPhysicalDeviceOption(id: "camera-2", name: "USB Capture HDMI", isExternal: true),
      ],
      audioDevices: [
        InputPhysicalDeviceOption(id: "audio-1", name: "USB Audio", isExternal: true)
      ],
      refreshPhysicalDevices: {},
      deleteInputDevice: { _ in }
    )
    .frame(width: 420, height: 360)
  }
#endif
