// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct WorkspaceContentPane: View {
  @State private var presentedCaptureFrameFeedback: OutputFrameCaptureFeedback?
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  var selectedProgramDefinitionName: String?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var portraitCompositeProgramDefinition: CompositeProgramDefinition
  var outputCanvas: OutputCanvasModel
  @Binding var previewSettings: AppPreviewSettings
  var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  /// Runtime for the Program selected in the Workspace window.
  var selectedProgramRuntime: ProgramRuntime
  var selectedPortraitProgramRuntime: ProgramRuntime
  var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  @Binding var programPreferences: ProgramPreferences
  @Binding var portraitProgramPreferences: ProgramPreferences
  var activeProgramCanvasRole: Binding<ProgramCanvasRole> = .constant(.landscape)
  @Binding var syncsLandscapeMixToPortrait: Bool
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?
  var supportsBackgroundRemoval: Bool
  @Binding var workspaceAudioChannels: [ProgramAudioChannel]
  var inputCameraDeviceMappings: [String: String]
  var audioPeakMeter: ProgramAudioPeakMeter
  var inputAudioPassthroughChannelKeys: Binding<Set<String>>
  var updateProgramAudioGains: (ProgramPreferences) -> Void
  var windowState = WorkspaceWindowState(
    mode: .edit,
    outputSessionState: .idle,
    isOperationLocked: false
  )
  var captureFrameFeedback: Binding<OutputFrameCaptureFeedback?> = .constant(nil)
  var programRecords: [SavedProgramDefinitionRecord] = []
  var addProgram: (String) -> Void = { _ in }
  var renameProgram: (String, String) -> Bool = { _, _ in false }
  var deleteProgram: (String) -> Void = { _ in }
  var moveProgram: (String, Int) -> Void = { _, _ in }
  var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool = { _ in false }

  var body: some View {
    content
      .id(contentIdentity)
      .overlay(alignment: .top) {
        if let feedback = presentedCaptureFrameFeedback {
          captureToast(feedback)
            .padding(16)
            .transition(.opacity)
        }
      }
      .task(id: captureFrameFeedback.wrappedValue?.id) {
        await presentCaptureFrameFeedback()
      }
      .onAppear { synchronizePortraitMixIfNeeded() }
      .onChange(of: syncsLandscapeMixToPortrait) { _, _ in
        synchronizePortraitMixIfNeeded()
      }
      .onChange(of: compositeProgramDefinition.audioChannels) { _, _ in
        synchronizePortraitMixIfNeeded()
      }
      .onChange(of: selectedProgramDefinitionName) { _, _ in
        synchronizePortraitMixIfNeeded()
      }
  }

  @ViewBuilder
  private var content: some View {
    switch contentSelection {
    case .program:
      programContent
    case .programs:
      ProgramManagementPane(
        programs: programRecords,
        selectedProgramName: selectedProgramDefinitionName,
        addProgram: addProgram,
        renameProgram: renameProgram,
        deleteProgram: deleteProgram,
        moveProgram: moveProgram
      )
      .disabled(windowState.mode == .output || windowState.isOperationLocked)
    case .inputDevice(let id):
      if let inputDevice = workspaceInputDevices.first(where: { $0.id == id }) {
        WorkspaceInputDevicePreviewPane(
          inputDevice: inputDevice,
          workspaceInputDevices: workspaceInputDevices,
          outputCanvas: outputCanvas,
          previewSettings: $previewSettings,
          workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
          lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
          backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
        )
      }
    case .videoComponent(let id):
      if let component = workspaceVideoComponents.first(where: { $0.id == id }) {
        if component.component.definition.isFill {
          programContent
        } else {
          WorkspaceVideoComponentPreviewPane(
            component: component,
            workspaceInputDevices: workspaceInputDevices,
            outputCanvas: outputCanvas,
            previewSettings: $previewSettings,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
            backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
            supportsBackgroundRemoval: supportsBackgroundRemoval
          )
        }
      }
    case .empty:
      ContentUnavailableView(
        "No Preview",
        systemImage: "rectangle.slash",
        description: Text("Select Output, an Input Device, or a Video Component in the sidebar.")
      )
      .accessibilityIdentifier("workspaceContentEmptyState")
    }
  }

  private var programContent: some View {
    ProgramContentPane(
      selectedSidebarItem: $selectedSidebarItem,
      selectedProgramDefinitionName: selectedProgramDefinitionName,
      compositeProgramDefinition: $compositeProgramDefinition,
      portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
      outputCanvas: outputCanvas,
      previewSettings: $previewSettings,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      programRuntime: selectedProgramRuntime,
      portraitProgramRuntime: selectedPortraitProgramRuntime,
      selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
      programPreferences: $programPreferences,
      portraitProgramPreferences: $portraitProgramPreferences,
      activeProgramCanvasRole: activeProgramCanvasRole,
      syncsLandscapeMixToPortrait: $syncsLandscapeMixToPortrait,
      workspaceInputDevices: workspaceInputDevices,
      workspaceVideoComponents: workspaceVideoComponents,
      inputCameraDeviceMappings: inputCameraDeviceMappings,
      audioPeakMeter: audioPeakMeter,
      inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeys,
      updateProgramAudioGains: updateProgramAudioGains,
      saveProgramDefinitionRecord: saveProgramDefinitionRecord,
      windowState: windowState
    )
    .accessibilityIdentifier("workspaceProgramContent")
    .id(ObjectIdentifier(selectedProgramRuntime))
  }

  private var contentSelection: WorkspaceContentSelection {
    WorkspaceContentSelection.resolve(
      selectedSidebarItem: selectedSidebarItem,
      inputDevices: workspaceInputDevices,
      videoComponents: workspaceVideoComponents
    )
  }

  private func synchronizePortraitMixIfNeeded() {
    guard syncsLandscapeMixToPortrait else { return }
    portraitCompositeProgramDefinition.audioChannels = compositeProgramDefinition.audioChannels
    portraitProgramPreferences.audioChannelGainsByName =
      programPreferences.audioChannelGainsByName
    portraitProgramPreferences.audioMutedByInputDeviceName =
      programPreferences.audioMutedByInputDeviceName
  }

  /// Fill selection changes only the Detail Pane. Its central surface stays
  /// on the Program Preview, so it must share the Program identity and keep
  /// the preview renderer alive rather than recreating it on selection.
  private var contentIdentity: WorkspaceContentSelection {
    guard case .videoComponent(let id) = contentSelection,
      let component = workspaceVideoComponents.first(where: { $0.id == id }),
      component.component.definition.isFill
    else {
      return contentSelection
    }
    return .program
  }

  private func presentCaptureFrameFeedback() async {
    var removalTransaction = Transaction()
    removalTransaction.disablesAnimations = true
    withTransaction(removalTransaction) {
      presentedCaptureFrameFeedback = nil
    }

    guard let feedback = captureFrameFeedback.wrappedValue else { return }
    await Task.yield()
    guard !Task.isCancelled, captureFrameFeedback.wrappedValue?.id == feedback.id else { return }
    withAnimation(.easeInOut(duration: 0.2)) { presentedCaptureFrameFeedback = feedback }

    try? await Task.sleep(for: .seconds(feedback.isError ? 5 : 3))
    guard !Task.isCancelled, captureFrameFeedback.wrappedValue?.id == feedback.id else { return }
    withAnimation(.easeInOut(duration: 0.2)) { presentedCaptureFrameFeedback = nil }
    captureFrameFeedback.wrappedValue = nil
  }

  private func captureToast(_ feedback: OutputFrameCaptureFeedback) -> some View {
    HStack(spacing: 10) {
      Image(
        systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
      )
      .foregroundStyle(feedback.isError ? .red : .green)
      Text(feedback.message)
        .lineLimit(2)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: Capsule())
    .shadow(radius: 8, y: 3)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("captureFramesToast")
  }
}

enum WorkspaceContentSelection: Hashable {
  case program
  case programs
  case inputDevice(String)
  case videoComponent(String)
  case empty

  static func resolve(
    selectedSidebarItem: WorkspaceSidebarItem?,
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord]
  ) -> WorkspaceContentSelection {
    switch selectedSidebarItem {
    case .output, .canvas, .videoLayers, .vision:
      return .program
    case .programs:
      return .programs
    case .inputDevice(let id) where inputDevices.contains(where: { $0.id == id }):
      return .inputDevice(id)
    case .videoComponent(let id) where videoComponents.contains(where: { $0.id == id }):
      return .videoComponent(id)
    default:
      return .empty
    }
  }
}

enum WorkspaceResourcePreviewFactory {
  static func inputDeviceComposite(_ inputDevice: WorkspaceInputDeviceRecord)
    -> CompositeProgramDefinition
  {
    return CompositeProgramDefinition(steps: [
      CompositeProgramStep(
        displayName: inputDevice.name,
        component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: inputDevice.id))
      )
    ])
  }

  static func videoComponentComposite(
    _ component: WorkspaceVideoComponentRecord,
    supportsBackgroundRemoval: Bool
  ) -> CompositeProgramDefinition {
    var previewComponent = component.component
    if case .inputCameraDevice(var payload) = previewComponent {
      payload.destinationX = 0
      payload.destinationY = 0
      payload.destinationScale = 1
      payload.removesBackground = supportsBackgroundRemoval && payload.removesBackground
      previewComponent = .inputCameraDevice(payload)
    } else if case .clock(var payload) = previewComponent {
      // A Video Component preview shows the component itself, not its
      // eventual Program placement. Give Clock the entire preview canvas;
      // its renderer aspect-fits the text block within these bounds.
      payload.destinationX = 0
      payload.destinationY = 0
      payload.destinationWidth = 1
      payload.destinationHeight = 1
      previewComponent = .clock(payload)
    }
    return CompositeProgramDefinition(steps: [
      CompositeProgramStep(
        displayName: component.name,
        component: previewComponent
      )
    ])
  }
}

struct WorkspaceInputDevicePreviewPane: View {
  let inputDevice: WorkspaceInputDeviceRecord
  let workspaceInputDevices: [WorkspaceInputDeviceRecord]
  let outputCanvas: OutputCanvasModel
  @Binding var previewSettings: AppPreviewSettings
  let workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?

  var body: some View {
    Group {
      switch inputDevice.kind {
      case .video:
        if inputDevice.physicalDeviceID == nil {
          ContentUnavailableView(
            "No Camera Selected",
            systemImage: "video.slash",
            description: Text("Choose a physical camera in the Detail Pane.")
          )
        } else {
          ProgramPreviewPane(
            title: "\(inputDevice.name) Preview",
            outputCanvas: outputCanvas,
            previewSettings: $previewSettings,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
            lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
            selectedProgramDefinitionRecord: nil,
            compositeProgramDefinition: WorkspaceResourcePreviewFactory.inputDeviceComposite(
              inputDevice),
            workspaceInputDevices: workspaceInputDevices,
            workspaceAudioChannels: [],
            inputCameraDeviceMappings: [:]
          )
          .padding()
        }
      case .audio:
        if let physicalDeviceID = inputDevice.physicalDeviceID {
          VStack(alignment: .leading, spacing: 12) {
            Text("\(inputDevice.name) Preview")
              .font(.headline)
            AudioInputSpectrogramPane(
              audioDeviceID: physicalDeviceID,
              captureSessionCoordinator: workspaceCaptureSessionCoordinator)
          }
          .padding()
        } else {
          ContentUnavailableView(
            "No Audio Device Selected",
            systemImage: "waveform.slash",
            description: Text("Choose a physical audio device in the Detail Pane.")
          )
        }
      case .unspecified:
        ContentUnavailableView(
          "Unsupported Input Device", systemImage: "questionmark.square.dashed")
      }
    }
    .accessibilityIdentifier("workspaceInputDevicePreview")
  }
}

struct WorkspaceVideoComponentPreviewPane: View {
  let component: WorkspaceVideoComponentRecord
  let workspaceInputDevices: [WorkspaceInputDeviceRecord]
  let outputCanvas: OutputCanvasModel
  @Binding var previewSettings: AppPreviewSettings
  let workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?
  let supportsBackgroundRemoval: Bool

  var body: some View {
    Group {
      if canRenderPreview {
        VStack(spacing: 0) {
          if component.removesBackground && !supportsBackgroundRemoval {
            Label(
              "Background removal is unavailable in this app target. The preview shows Crop only.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top)
          }
          ProgramPreviewPane(
            title: "\(component.name) Preview",
            outputCanvas: outputCanvas,
            previewSettings: $previewSettings,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
            lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
            selectedProgramDefinitionRecord: nil,
            compositeProgramDefinition: WorkspaceResourcePreviewFactory.videoComponentComposite(
              component,
              supportsBackgroundRemoval: supportsBackgroundRemoval
            ),
            workspaceInputDevices: workspaceInputDevices,
            workspaceAudioChannels: [],
            inputCameraDeviceMappings: [:]
          )
          .padding()
        }
      } else if component.component.definition.usesInputCameraDevice {
        ContentUnavailableView(
          "No Video Input Available",
          systemImage: "video.slash",
          description: Text("Choose a configured Video Input Device in the Detail Pane.")
        )
      } else {
        ContentUnavailableView("Preview Unavailable", systemImage: "rectangle.slash")
      }
    }
    .accessibilityIdentifier("workspaceVideoComponentPreview")
  }

  private var selectedInputDevice: WorkspaceInputDeviceRecord? {
    guard let inputDeviceID = component.inputDeviceID else { return nil }
    return workspaceInputDevices.first { $0.id == inputDeviceID }
  }

  private var canRenderPreview: Bool {
    guard component.component.definition.usesInputCameraDevice else { return true }
    return selectedInputDevice?.kind == .video && selectedInputDevice?.physicalDeviceID != nil
  }
}

#if DEBUG
  #Preview("Workspace Content") {
    WorkspaceContentPanePreviewHost()
      .frame(width: 560, height: 620)
  }

  private struct WorkspaceContentPanePreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var selectedProgramDefinitionName =
      LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var portraitCompositeProgramDefinition = CompositeProgramDefinition()
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var previewSettings = LDTXAppUIPreviewFixtures.makeAppPreviewSettings()
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    @State private var portraitProgramPreferences = ProgramPreferences()
    @State private var syncsLandscapeMixToPortrait = false
    @State private var workspaceAudioChannels = LDTXAppUIPreviewFixtures.workspaceAudioChannels
    private let workspaceCaptureSessionCoordinator =
      LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator()
    private let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    private var previewRuntime: ProgramRuntime {
      LDTXAppUIPreviewFixtures.makeProgramRuntime(
        coordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
      )
    }

    var body: some View {
      WorkspaceContentPane(
        selectedSidebarItem: $selectedSidebarItem,
        selectedProgramDefinitionName: selectedProgramDefinitionName,
        compositeProgramDefinition: $compositeProgramDefinition,
        portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
        outputCanvas: outputCanvas,
        previewSettings: $previewSettings,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        selectedProgramRuntime: previewRuntime,
        selectedPortraitProgramRuntime: previewRuntime,
        selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
        programPreferences: $programPreferences,
        portraitProgramPreferences: $portraitProgramPreferences,
        syncsLandscapeMixToPortrait: $syncsLandscapeMixToPortrait,
        workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
        workspaceVideoComponents: [],
        backgroundRemovalPreprocessorFactory: nil,
        supportsBackgroundRemoval: false,
        workspaceAudioChannels: $workspaceAudioChannels,
        inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
        audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
        inputAudioPassthroughChannelKeys: .constant([]),
        updateProgramAudioGains: { programPreferences = $0 }
      )
    }
  }
#endif
