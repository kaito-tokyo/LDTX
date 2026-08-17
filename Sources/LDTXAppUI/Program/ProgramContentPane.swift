// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct ProgramContentPane: View {
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  var selectedProgramDefinitionName: String?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var portraitCompositeProgramDefinition: CompositeProgramDefinition
  var outputCanvas: OutputCanvasModel
  @Binding var previewSettings: AppPreviewSettings
  var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  var programRuntime: ProgramRuntime
  var portraitProgramRuntime: ProgramRuntime
  var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  @Binding var programPreferences: ProgramPreferences
  @Binding var portraitProgramPreferences: ProgramPreferences
  var activeProgramCanvasRole: Binding<ProgramCanvasRole> = .constant(.landscape)
  @Binding var syncsLandscapeMixToPortrait: Bool
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var inputCameraDeviceMappings: [String: String]
  var audioPeakMeter: ProgramAudioPeakMeter
  var inputAudioPassthroughChannelKeys: Binding<Set<String>>
  var updateProgramAudioGains: (ProgramPreferences) -> Void
  var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool = { _ in false }
  var windowState = WorkspaceWindowState(
    mode: .edit,
    outputSessionState: .idle,
    isOperationLocked: false
  )
  @State private var isShowingProgramPreferencesJSON = false
  @State private var isShowingProgramDefinitionJSON = false
  @State private var pendingVideoCopy: ProgramCanvasRole?

  var body: some View {
    Form {
      Section {
        EqualCanvasHeightPreviewLayout(
          aspectRatios: [
            outputCanvas.previewAspectRatio,
            portraitOutputCanvas.previewAspectRatio,
          ],
          spacing: 16
        ) {
          canvasPreview(
            title: "Landscape Canvas",
            role: .landscape,
            outputCanvas: outputCanvas,
            runtime: programRuntime,
            composite: compositeProgramDefinition
          )
          canvasPreview(
            title: "Portrait Canvas",
            role: .portrait,
            outputCanvas: portraitOutputCanvas,
            runtime: portraitProgramRuntime,
            composite: portraitCompositeProgramDefinition
          )
        }
      }

      Section("Canvas Actions") {
        canvasActions
      }

      Section("Audio Mix Actions") {
        audioMixActions
      }

      if !activeAudioChannels.isEmpty {
        Section("Audio Mix") {
          ForEach(activeAudioChannels.indices, id: \.self) { index in
            let channel = activeAudioChannels[index]
            let channelKey = activeAudioChannels.audioChannelKey(for: channel)
            HStack(spacing: 8) {
              AudioChannelControl(
                label: audioChannelLabel(for: channel),
                value: audioChannelGain(for: channel),
                peakProvider: {
                  audioPeakMeter.peak(for: channelKey)
                },
                onPreview: { gain in
                  previewAudioChannelGain(gain, for: channel)
                },
                onCommit: { gain in
                  commitAudioChannelGain(gain, for: channel)
                }
              )

              if isInputAudioDeviceChannel(channel) {
                Button {
                  toggleAudioMute(for: channel)
                } label: {
                  Image(
                    systemName: isAudioMuted(for: channel)
                      ? "speaker.slash.fill" : "speaker.wave.2.fill"
                  )
                }
                .buttonStyle(.borderless)
                .help(
                  isAudioMuted(for: channel)
                    ? "Unmute \(audioChannelLabel(for: channel))"
                    : "Mute \(audioChannelLabel(for: channel))"
                )
                .accessibilityLabel(
                  isAudioMuted(for: channel) ? "Unmute audio" : "Mute audio"
                )

                Toggle(
                  "",
                  isOn: inputAudioPassthroughBinding(for: channelKey)
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Play \(audioChannelLabel(for: channel)) through this app")
              }
            }
          }
        }
        .disabled(
          activeProgramCanvasRole.wrappedValue == .portrait
            && syncsLandscapeMixToPortrait)
      }

      Section {
        HStack {
          Spacer()

          Button {
            isShowingProgramDefinitionJSON = true
          } label: {
            Label("Program JSON", systemImage: "curlybraces")
          }
          .accessibilityIdentifier("showProgramDefinitionJSONButton")
          .disabled(windowState.mode != .edit || windowState.isOperationLocked)

          Button {
            isShowingProgramPreferencesJSON = true
          } label: {
            Label("Preferences JSON", systemImage: "curlybraces")
          }
          .accessibilityIdentifier("showProgramPreferencesJSONButton")
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $isShowingProgramPreferencesJSON) {
      ProgramPreferencesJSONView(jsonText: programPreferencesJSONText)
    }
    .sheet(isPresented: $isShowingProgramDefinitionJSON) {
      ProgramDefinitionJSONView(jsonText: programDefinitionJSONText)
    }
    .onAppear { applyCurrentVideoLayerPreferences() }
    .onChange(of: compositeProgramDefinition.audioChannels) { _, _ in
      if syncsLandscapeMixToPortrait { copyLandscapeMixToPortrait() }
    }
    .onChange(of: programPreferences) { _, _ in
      if syncsLandscapeMixToPortrait { copyLandscapeMixToPortrait() }
    }
    .confirmationDialog(
      "Replace the destination Canvas video layers?",
      isPresented: Binding(
        get: { pendingVideoCopy != nil },
        set: { if !$0 { pendingVideoCopy = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Replace Video Layers", role: .destructive) { performPendingVideoCopy() }
      Button("Cancel", role: .cancel) { pendingVideoCopy = nil }
    }
  }

  private var canvasActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        canvasActionControls
      }
      VStack(alignment: .leading) {
        canvasActionControls
      }
    }
  }

  @ViewBuilder
  private var canvasActionControls: some View {
    Button("Copy Landscape to Portrait") { pendingVideoCopy = .portrait }
    Button("Copy Portrait to Landscape") { pendingVideoCopy = .landscape }
  }

  private var audioMixActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        audioMixActionControls
      }
      VStack(alignment: .leading) {
        audioMixActionControls
      }
    }
  }

  @ViewBuilder
  private var audioMixActionControls: some View {
    Button("Copy Landscape Mix to Portrait Mix") {
      copyLandscapeMixToPortrait()
    }
    Button("Copy Portrait Mix to Landscape Mix") {
      copyPortraitMixToLandscape()
    }
    .disabled(syncsLandscapeMixToPortrait)
    Toggle("Sync Landscape Mix to Portrait Mix", isOn: $syncsLandscapeMixToPortrait)
      .onChange(of: syncsLandscapeMixToPortrait) { _, enabled in
        if enabled { copyLandscapeMixToPortrait() }
      }
  }

  private var portraitOutputCanvas: OutputCanvasModel {
    OutputCanvasModel(
      canvasSize: .init(width: 1_080, height: 1_920),
      programDefinitionFrameRate: 60
    )
  }

  @ViewBuilder
  private func canvasPreview(
    title: String,
    role: ProgramCanvasRole,
    outputCanvas: OutputCanvasModel,
    runtime: ProgramRuntime,
    composite: CompositeProgramDefinition
  ) -> some View {
    VStack {
      ProgramPreviewPane(
        title: title,
        outputCanvas: outputCanvas,
        previewSettings: $previewSettings,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        stacksPreviewHeader: true,
        programRuntime: runtime,
        selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
        compositeProgramDefinition: composite,
        workspaceInputDevices: workspaceInputDevices,
        workspaceAudioChannels: composite.audioChannels,
        inputCameraDeviceMappings: inputCameraDeviceMappings
      )
      .contentShape(Rectangle())
      .onTapGesture {
        activeProgramCanvasRole.wrappedValue = role
        selectedSidebarItem = .output
      }
    }
  }

  private func performPendingVideoCopy() {
    defer { pendingVideoCopy = nil }
    switch pendingVideoCopy {
    case .portrait:
      portraitCompositeProgramDefinition.steps = compositeProgramDefinition.steps
      copyVideoLayerPreferences(
        from: programPreferences, to: &portraitProgramPreferences,
        xScale: 1_080.0 / 1_920.0, yScale: 1_920.0 / 1_080.0)
      _ = saveProgramDefinitionRecord(currentProgramDefinitionRecord)
    case .landscape:
      compositeProgramDefinition.steps = portraitCompositeProgramDefinition.steps
      copyVideoLayerPreferences(
        from: portraitProgramPreferences, to: &programPreferences,
        xScale: 1_920.0 / 1_080.0, yScale: 1_080.0 / 1_920.0)
      _ = saveProgramDefinitionRecord(currentProgramDefinitionRecord)
    case nil:
      break
    }
  }

  private func copyVideoLayerPreferences(
    from source: ProgramPreferences,
    to destination: inout ProgramPreferences,
    xScale: Float,
    yScale: Float
  ) {
    let programName =
      selectedProgramDefinitionName ?? selectedProgramDefinitionRecord?.name
      ?? "New Program"
    let layers = source.videoLayers(forProgramNamed: programName).map { layer in
      var layer = layer
      layer.destinationX *= xScale
      layer.destinationY *= yScale
      return layer
    }
    destination.setVideoLayers(layers, forProgramNamed: programName)
  }

  private func copyLandscapeMixToPortrait() {
    portraitCompositeProgramDefinition.audioChannels = compositeProgramDefinition.audioChannels
    portraitProgramPreferences.audioChannelGainsByName =
      programPreferences.audioChannelGainsByName
    portraitProgramPreferences.audioMutedByInputDeviceName =
      programPreferences.audioMutedByInputDeviceName
  }

  private func copyPortraitMixToLandscape() {
    compositeProgramDefinition.audioChannels = portraitCompositeProgramDefinition.audioChannels
    programPreferences.audioChannelGainsByName =
      portraitProgramPreferences.audioChannelGainsByName
    programPreferences.audioMutedByInputDeviceName =
      portraitProgramPreferences.audioMutedByInputDeviceName
  }

  private func applyCurrentVideoLayerPreferences() {
    let programName =
      selectedProgramDefinitionName ?? selectedProgramDefinitionRecord?.name ?? "New Program"
    if activeProgramCanvasRole.wrappedValue == .portrait {
      portraitCompositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
        workspaceVideoComponents,
        layers: portraitProgramPreferences.videoLayers(forProgramNamed: programName),
        to: portraitCompositeProgramDefinition,
        coordinateWidth: 1_080,
        coordinateHeight: 1_920)
    } else {
      compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
        workspaceVideoComponents,
        layers: programPreferences.videoLayers(forProgramNamed: programName),
        to: compositeProgramDefinition,
        coordinateWidth: 1_920,
        coordinateHeight: 1_080)
    }
  }

  private var activeAudioChannels: [ProgramAudioChannel] {
    activeProgramCanvasRole.wrappedValue == .portrait
      ? portraitCompositeProgramDefinition.audioChannels
      : compositeProgramDefinition.audioChannels
  }

  private var activeAudioPreferences: ProgramPreferences {
    activeProgramCanvasRole.wrappedValue == .portrait
      ? portraitProgramPreferences
      : programPreferences
  }

  private func audioChannelGain(for channel: ProgramAudioChannel) -> Double {
    activeAudioPreferences.audioChannelGain(for: channel, in: activeAudioChannels)
  }

  private func previewAudioChannelGain(_ gain: Double, for channel: ProgramAudioChannel) {
    var previewPreferences = activeAudioPreferences
    previewPreferences.setAudioChannelGain(
      gain,
      for: channel,
      in: activeAudioChannels
    )
    updateProgramAudioGains(previewPreferences)
  }

  private func commitAudioChannelGain(_ gain: Double, for channel: ProgramAudioChannel) {
    if activeProgramCanvasRole.wrappedValue == .portrait {
      portraitProgramPreferences.setAudioChannelGain(gain, for: channel, in: activeAudioChannels)
      updateProgramAudioGains(portraitProgramPreferences)
    } else {
      programPreferences.setAudioChannelGain(gain, for: channel, in: activeAudioChannels)
      updateProgramAudioGains(programPreferences)
    }
  }

  private func audioChannelLabel(for channel: ProgramAudioChannel) -> String {
    if case .inputAudioDevice(let payload) = channel.component,
      let inputDeviceID = payload.inputDeviceID,
      let inputDevice = workspaceInputDevices.first(where: { $0.id == inputDeviceID })
    {
      return inputDevice.name
    }
    return activeAudioChannels.audioChannelDisplayName(for: channel)
  }

  private func isInputAudioDeviceChannel(_ channel: ProgramAudioChannel) -> Bool {
    if case .inputAudioDevice = channel.component {
      return true
    }
    return false
  }

  private func inputAudioDeviceID(for channel: ProgramAudioChannel) -> String? {
    guard case .inputAudioDevice(let payload) = channel.component else { return nil }
    return payload.inputDeviceID
  }

  private func isAudioMuted(for channel: ProgramAudioChannel) -> Bool {
    guard let inputDeviceID = inputAudioDeviceID(for: channel) else { return false }
    return activeAudioPreferences.isAudioMuted(inputDeviceName: inputDeviceID)
  }

  private func toggleAudioMute(for channel: ProgramAudioChannel) {
    guard let inputDeviceID = inputAudioDeviceID(for: channel) else { return }
    if activeProgramCanvasRole.wrappedValue == .portrait {
      portraitProgramPreferences.setAudioMuted(
        !portraitProgramPreferences.isAudioMuted(inputDeviceName: inputDeviceID),
        inputDeviceName: inputDeviceID
      )
      updateProgramAudioGains(portraitProgramPreferences)
    } else {
      programPreferences.setAudioMuted(
        !programPreferences.isAudioMuted(inputDeviceName: inputDeviceID),
        inputDeviceName: inputDeviceID
      )
      updateProgramAudioGains(programPreferences)
    }
  }

  private func inputAudioPassthroughBinding(for channelKey: String) -> Binding<Bool> {
    let selectionKey = "\(activeProgramCanvasRole.wrappedValue.rawValue):\(channelKey)"
    return Binding(
      get: {
        inputAudioPassthroughChannelKeys.wrappedValue.contains(selectionKey)
      },
      set: { isEnabled in
        var channelKeys = inputAudioPassthroughChannelKeys.wrappedValue
        if isEnabled {
          channelKeys.insert(selectionKey)
        } else {
          channelKeys.remove(selectionKey)
        }
        inputAudioPassthroughChannelKeys.wrappedValue = channelKeys
      }
    )
  }

  private var programPreferencesJSONText: String {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let preferences =
        activeProgramCanvasRole.wrappedValue == .landscape
        ? programPreferences : portraitProgramPreferences
      let data = try encoder.encode(preferences)
      return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return """
        {
          "error" : "\(diagnosticDescription(error))"
        }
        """
    }
  }

  private var currentProgramDefinitionRecord: SavedProgramDefinitionRecord {
    SavedProgramDefinitionRecord(
      name: selectedProgramDefinitionRecord?.name ?? selectedProgramDefinitionName ?? "New Program",
      landscape: ProgramCanvasDefinition(
        canvasWidth: 1_920,
        canvasHeight: 1_080,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: outputCanvas.applying(to: compositeProgramDefinition)
      ),
      portrait: ProgramCanvasDefinition(
        canvasWidth: 1_080,
        canvasHeight: 1_920,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: portraitCompositeProgramDefinition
      ),
      inputDevices: []
    )
  }

  private var programDefinitionJSONText: String {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(currentProgramDefinitionRecord)
      return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return """
        {
          "error" : "\(diagnosticDescription(error))"
        }
        """
    }
  }

  private func diagnosticDescription(_ error: Error) -> String {
    String(describing: error)
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}

private struct EqualCanvasHeightPreviewLayout: Layout {
  var aspectRatios: [CGFloat]
  var spacing: CGFloat
  var idealWidth: CGFloat = 480

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Void
  ) -> CGSize {
    let availableWidth = proposal.width ?? idealWidth
    let widths = previewWidths(availableWidth: availableWidth, subviewCount: subviews.count)
    let sizes = zip(subviews, widths).map { subview, width in
      subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    return CGSize(
      width: widths.reduce(0, +) + totalSpacing(subviewCount: subviews.count),
      height: sizes.map(\.height).max() ?? 0
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Void
  ) {
    let widths = previewWidths(availableWidth: bounds.width, subviewCount: subviews.count)
    var x = bounds.minX
    for (subview, width) in zip(subviews, widths) {
      subview.place(
        at: CGPoint(x: x, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: bounds.height)
      )
      x += width + spacing
    }
  }

  private func previewWidths(availableWidth: CGFloat, subviewCount: Int) -> [CGFloat] {
    let ratios = Array(aspectRatios.prefix(subviewCount))
    guard ratios.count == subviewCount else {
      return Array(repeating: 0, count: subviewCount)
    }
    let contentWidth = max(availableWidth - totalSpacing(subviewCount: subviewCount), 0)
    let ratioTotal = ratios.reduce(0, +)
    guard ratioTotal > 0 else {
      return Array(repeating: 0, count: subviewCount)
    }
    let previewHeight = contentWidth / ratioTotal
    return ratios.map { $0 * previewHeight }
  }

  private func totalSpacing(subviewCount: Int) -> CGFloat {
    spacing * CGFloat(max(subviewCount - 1, 0))
  }
}

extension OutputCanvasModel {
  fileprivate var previewAspectRatio: CGFloat {
    CGFloat(canvasSize.width) / CGFloat(max(canvasSize.height, 1))
  }
}

#if DEBUG
  #Preview("Program Content") {
    ProgramContentPanePreviewHost()
      .frame(width: 560, height: 620)
  }

  private struct ProgramContentPanePreviewHost: View {
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var portraitCompositeProgramDefinition = CompositeProgramDefinition()
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var previewSettings = LDTXAppUIPreviewFixtures.makeAppPreviewSettings()
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    @State private var portraitProgramPreferences = ProgramPreferences()
    @State private var syncsLandscapeMixToPortrait = false
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
      ProgramContentPane(
        selectedSidebarItem: .constant(nil),
        selectedProgramDefinitionName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
        compositeProgramDefinition: $compositeProgramDefinition,
        portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
        outputCanvas: outputCanvas,
        previewSettings: $previewSettings,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        programRuntime: previewRuntime,
        portraitProgramRuntime: previewRuntime,
        selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
        programPreferences: $programPreferences,
        portraitProgramPreferences: $portraitProgramPreferences,
        syncsLandscapeMixToPortrait: $syncsLandscapeMixToPortrait,
        workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
        workspaceVideoComponents: [],
        inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
        audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
        inputAudioPassthroughChannelKeys: .constant([]),
        updateProgramAudioGains: { programPreferences = $0 }
      )
    }
  }
#endif
