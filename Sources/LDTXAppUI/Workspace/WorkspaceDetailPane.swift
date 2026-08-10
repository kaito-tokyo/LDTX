// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

public struct ProgramDefinitionSaveCommand {
  public var isEnabled: Bool
  public var perform: () -> Void

  public init(isEnabled: Bool, perform: @escaping () -> Void) {
    self.isEnabled = isEnabled
    self.perform = perform
  }
}

struct WorkspaceDetailPane: View {
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var programPreferences: ProgramPreferences
  var outputCanvas: OutputCanvasModel
  var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  @Binding var visions: [WorkspaceVisionDefinition]
  @Binding var videoComponents: [WorkspaceVideoComponentRecord]
  @Binding var videoPTSMasterInputDeviceID: String?
  var visionRuntimePresenter: any VisionRuntimePresenting
  var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil
  var analyzeVision: (WorkspaceVisionDefinition) -> Void
  var cameras: [InputPhysicalDeviceOption]
  var audioDevices: [InputPhysicalDeviceOption]
  var refreshCameras: () -> Void
  var deleteWorkspaceInputDevice: (String) -> Void
  var deleteWorkspaceVideoComponent: (String) -> Void = { _ in }
  var deleteWorkspaceVision: (String) -> Void = { _ in }
  var workspaceInputDeviceOptions: [WorkspaceInputDeviceRecord]
  var outputDestination: OutputDestination
  var selectedBroadcastID: String? = nil
  var selectedProgramName: String? = nil
  var windowState: WorkspaceWindowState = WorkspaceWindowState(
    mode: .edit,
    outputSessionState: .idle,
    isOperationLocked: false
  )
  var isOutputSessionStartEnabled: Bool = false
  var outputSessionStartLabel: String = "Start Output"
  var showsOutputSessionControls: Bool = true
  var existingBroadcasts: [LiveBroadcastSummary]
  var isLoadingBroadcasts: Bool
  var featureAvailability: WorkspaceFeatureAvailability = .all
  var refreshExistingBroadcasts: () -> Void
  var manageYouTubeBroadcasts: () -> Void
  var chooseOutputDirectory: () -> URL? = { nil }
  var applyOutputSettings: (OutputDestination) -> Void = { _ in }
  var selectBroadcast: (String?) -> Void = { _ in }
  var captureFrame: () -> Void = {}
  var openScreenshotsDirectory: () -> Void = {}
  var verifyRecording: () -> Void = {}
  var startOutputSession: () -> Void = {}
  var pauseOutputSession: () -> Void = {}
  var stopOutputSession: () -> Void = {}

  var body: some View {
    switch detailContentSelection {
    case .output:
      OutputOrchestrationDetailPane(
        selectedProgramName: selectedProgramName,
        windowState: windowState,
        isOutputSessionStartEnabled: isOutputSessionStartEnabled,
        outputSessionStartLabel: outputSessionStartLabel,
        showsSessionControls: showsOutputSessionControls,
        outputDestination: outputDestination,
        selectedBroadcastID: selectedBroadcastID,
        existingBroadcasts: existingBroadcasts,
        isLoadingBroadcasts: isLoadingBroadcasts,
        supportsYouTube: featureAvailability.supportsYouTube,
        refreshExistingBroadcasts: refreshExistingBroadcasts,
        manageYouTubeBroadcasts: manageYouTubeBroadcasts,
        chooseOutputDirectory: chooseOutputDirectory,
        applyOutputSettings: applyOutputSettings,
        selectBroadcast: selectBroadcast,
        captureFrame: captureFrame,
        openScreenshotsDirectory: openScreenshotsDirectory,
        verifyRecording: verifyRecording,
        startOutputSession: startOutputSession,
        pauseOutputSession: pauseOutputSession,
        stopOutputSession: stopOutputSession
      )
    case .canvas:
      CanvasDetailPane(
        outputCanvas: outputCanvas,
        windowState: windowState,
        videoPTSMasterInputDeviceID: $videoPTSMasterInputDeviceID,
        videoPTSMasterInputDeviceOptions: workspaceInputDeviceOptions.filter { $0.kind == .video }
      )
    case .videoLayers:
      VideoLayersDetailPane(
        selectedProgramDefinitionName: selectedProgramName,
        selectedProgramDefinitionRecord: nil,
        compositeProgramDefinition: $compositeProgramDefinition,
        programPreferences: $programPreferences,
        workspaceInputDevices: workspaceInputDevices,
        workspaceVideoComponents: videoComponents,
        windowState: windowState
      )
    case .programs:
      ProgramManagementHelpDetailPane()
    case .inputDevice:
      InputDeviceDetailPane(
        inputDevices: $workspaceInputDevices,
        selectedInputDeviceID: selectedInputDeviceID,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        cameras: cameras,
        audioDevices: audioDevices,
        refreshPhysicalDevices: refreshCameras,
        deleteInputDevice: deleteWorkspaceInputDevice,
        previewPlacement: .hidden,
        supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
      )
      .disabled(windowState.mode != .edit || windowState.isOperationLocked)
    case .videoComponent:
      WorkspaceVideoComponentDetailPane(
        videoComponents: $videoComponents,
        selectedSidebarItem: $selectedSidebarItem,
        workspaceInputDevices: workspaceInputDeviceOptions,
        deleteVideoComponent: deleteWorkspaceVideoComponent,
        isStructureEditable: windowState.mode == .edit && !windowState.isOperationLocked,
        supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval
      )
      .disabled(!isSelectedVideoComponentContentEditable)
    case .vision:
      if case .some(.vision(let id)) = selectedSidebarItem {
        VisionDetailPane(
          visions: $visions,
          visionID: id,
          inputDevices: workspaceInputDevices,
          runtimePresenter: visionRuntimePresenter,
          analyze: analyzeVision,
          delete: deleteWorkspaceVision
        )
        // Vision can be configured while Output is running, but a
        // Workspace operation transition must not accept a new edit.
        // Existing Vision work keeps running independently.
        .disabled(
          !featureAvailability.supportsVision || windowState.isOperationLocked
        )
      }
    case .empty:
      WorkspaceDetailEmptyStateView()
    }
  }

  private var detailContentSelection: WorkspaceDetailContentSelection {
    if selectedSidebarItem == .output {
      return .output
    }
    if selectedSidebarItem == .canvas {
      return .canvas
    }
    if selectedSidebarItem == .videoLayers {
      return .videoLayers
    }
    if selectedSidebarItem == .programs {
      return .programs
    }
    if selectedInputDeviceExists {
      return .inputDevice
    }
    if selectedVideoComponentExists {
      return .videoComponent
    }
    if case .some(.vision(let id)) = selectedSidebarItem,
      visions.contains(where: { $0.id == id })
    {
      return .vision
    }
    return .empty
  }

  private var selectedInputDeviceExists: Bool {
    guard let selectedID = selectedInputDeviceID.wrappedValue else {
      return false
    }
    return workspaceInputDevices.contains { $0.id == selectedID }
  }

  private var selectedInputDeviceID: Binding<String?> {
    Binding(
      get: {
        if case .some(.inputDevice(let id)) = selectedSidebarItem {
          return id
        }
        return nil
      },
      set: { newValue in
        guard let newValue,
          workspaceInputDevices.contains(where: { $0.id == newValue })
        else {
          selectedSidebarItem = .output
          return
        }
        selectedSidebarItem = .inputDevice(newValue)
      }
    )
  }

  private var selectedVideoComponentExists: Bool {
    guard case .some(.videoComponent(let id)) = selectedSidebarItem else {
      return false
    }
    return videoComponents.contains { $0.id == id }
  }

  private var isSelectedVideoComponentContentEditable: Bool {
    guard !windowState.isOperationLocked else { return false }
    guard case .some(.videoComponent(let id)) = selectedSidebarItem,
      let component = videoComponents.first(where: { $0.id == id })
    else {
      return false
    }
    return windowState.mode == .edit || component.component.definition.isFill
  }

}

private struct ProgramManagementHelpDetailPane: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Programs")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 16)

      Form {
        Section("About Programs") {
          Text("Programs define the scenes available for preview and output.")
          Text(
            "Video Components are shared by Programs, while Video Layers determine which components each Program uses and their order."
          )
        }

        Section("Managing Programs") {
          LabeledContent("Order", value: "Controls Program selection order")
          LabeledContent("Rename", value: "Updates references across the Workspace")
          LabeledContent("Delete", value: "Unavailable for the current Program")
        }

        Section("Output") {
          Text("Program structure can be edited after stopping Output and returning to Edit Mode.")
        }
      }
      .formStyle(.grouped)
    }
    .accessibilityIdentifier("programManagementHelpDetailPane")
  }
}

private enum WorkspaceDetailContentSelection {
  case output
  case canvas
  case videoLayers
  case programs
  case inputDevice
  case videoComponent
  case vision
  case empty
}

#if DEBUG
  #Preview("Workspace Detail Empty") {
    WorkspaceDetailPaneEmptyPreviewHost()
      .frame(width: 560, height: 760)
  }

  #Preview("Workspace Detail Input Device") {
    WorkspaceDetailPaneInputPreviewHost()
      .frame(width: 560, height: 520)
  }

  private struct WorkspaceDetailPaneEmptyPreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var programPreferences = ProgramPreferences()
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var visions: [WorkspaceVisionDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()
    private let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    var body: some View {
      WorkspaceDetailPane(
        selectedSidebarItem: $selectedSidebarItem,
        compositeProgramDefinition: $compositeProgramDefinition,
        programPreferences: $programPreferences,
        outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
        workspaceCaptureSessionCoordinator:
          LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        workspaceInputDevices: $workspaceInputDevices,
        visions: $visions,
        videoComponents: .constant([]),
        videoPTSMasterInputDeviceID: .constant(nil),
        visionRuntimePresenter: visionRuntimePresenter,
        analyzeVision: { _ in },
        cameras: LDTXAppUIPreviewFixtures.cameras,
        audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
        refreshCameras: {},
        deleteWorkspaceInputDevice: { _ in },
        workspaceInputDeviceOptions: workspaceInputDevices,
        outputDestination: OutputDestination.newWorkspaceInitialValue,
        existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
        isLoadingBroadcasts: false,
        refreshExistingBroadcasts: {},
        manageYouTubeBroadcasts: {},
      )
    }
  }

  private struct WorkspaceDetailPaneInputPreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem? = .inputDevice(
      "workspace-video-1")
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var programPreferences = ProgramPreferences()
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var visions: [WorkspaceVisionDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()
    private let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    var body: some View {
      WorkspaceDetailPane(
        selectedSidebarItem: $selectedSidebarItem,
        compositeProgramDefinition: $compositeProgramDefinition,
        programPreferences: $programPreferences,
        outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
        workspaceCaptureSessionCoordinator:
          LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        workspaceInputDevices: $workspaceInputDevices,
        visions: $visions,
        videoComponents: .constant([]),
        videoPTSMasterInputDeviceID: .constant(nil),
        visionRuntimePresenter: visionRuntimePresenter,
        analyzeVision: { _ in },
        cameras: LDTXAppUIPreviewFixtures.cameras,
        audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
        refreshCameras: {},
        deleteWorkspaceInputDevice: { _ in },
        workspaceInputDeviceOptions: workspaceInputDevices,
        outputDestination: OutputDestination.newWorkspaceInitialValue,
        existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
        isLoadingBroadcasts: false,
        refreshExistingBroadcasts: {},
        manageYouTubeBroadcasts: {},
      )
    }
  }
#endif
