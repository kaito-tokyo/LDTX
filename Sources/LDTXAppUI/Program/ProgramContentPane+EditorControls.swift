// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct VideoLayersDetailPane: View {
  @State private var placementEditorSelection: VideoLayerPlacementEditorSelection?
  var selectedProgramDefinitionName: String?
  var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var programPreferences: ProgramPreferences
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var coordinateWidth: Float = 1_920
  var coordinateHeight: Float = 1_080
  var windowState: WorkspaceWindowState
  var accessibilityIdentifierPrefix = ""
  var placementEditorPresenter: ((VideoLayerPlacementEditorSelection) -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Video Layers")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 16)
      Form {
        videoComponentControls
      }
      .formStyle(.grouped)
    }
    .sheet(item: $placementEditorSelection) { selection in
      VideoLayerPlacementEditor(selection: selection)
    }
  }

  fileprivate var videoComponentControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      if videoLayers.isEmpty {
        Text("No video layers")
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 8) {
          ForEach(Array(videoLayers.enumerated()), id: \.element.id) { index, layer in
            videoLayerRow(for: layer, index: index)
          }
        }
      }

      Menu {
        if !availableVideoInputDevices.isEmpty {
          Section("Video Input Devices") {
            ForEach(availableVideoInputDevices) { device in
              Button(device.name) {
                addVideoInputDevice(device)
              }
            }
          }
        }
        if !availableWorkspaceVideoComponents.isEmpty {
          Section("Video Components") {
            ForEach(availableWorkspaceVideoComponents) { component in
              Button(component.name) {
                addWorkspaceVideoComponent(component)
              }
            }
          }
        }
      } label: {
        Label("Add Video Layer", systemImage: "plus")
      }
      .disabled(
        !isProgramStructureEditable
          || (availableWorkspaceVideoComponents.isEmpty && availableVideoInputDevices.isEmpty)
      )
      .accessibilityLabel("Add Video Layer")
      .accessibilityIdentifier(accessibilityIdentifier("addProgramComponentButton"))

      if workspaceVideoComponents.isEmpty {
        Text("Create a Video Component in the sidebar first.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if availableWorkspaceVideoComponents.isEmpty && availableVideoInputDevices.isEmpty {
        Text("All available Video Inputs and Video Components already have a Video Layer.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func videoLayerRow(
    for layer: VideoLayerPreference,
    index: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          setVideoLayerMuted(!layer.isMuted, at: index)
        } label: {
          Image(systemName: videoLayerSystemImage(named: layer.componentName))
        }
        .buttonStyle(.borderless)
        .help(layer.isMuted ? "Unmute Video Layer" : "Mute Video Layer")
        .accessibilityLabel(layer.isMuted ? "Unmute Video Layer" : "Mute Video Layer")
        .accessibilityValue(layer.isMuted ? "Muted" : "Unmuted")

        Text(layer.componentName)
          .lineLimit(1)
          .strikethrough(layer.isMuted)

        Spacer(minLength: 8)

        if layerSupportsDestination(layer) {
          Button {
            presentPlacementEditor(for: layer)
          } label: {
            Label("Edit Placement", systemImage: "rectangle.and.pencil.and.ellipsis")
          }
          .labelStyle(.iconOnly)
          .help("Edit Placement")
          .disabled(!isProgramStructureEditable)
          .accessibilityIdentifier(
            accessibilityIdentifier("editVideoLayerPlacementButton-\(layer.id)")
          )
        }

        Button {
          moveCompositeStep(index: index, offset: -1)
        } label: {
          Label("Move Up", systemImage: "arrow.up")
        }
        .labelStyle(.iconOnly)
        .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: -1))
        .accessibilityIdentifier(
          accessibilityIdentifier("moveVideoComponentUpButton-\(layer.id)")
        )

        Button {
          moveCompositeStep(index: index, offset: 1)
        } label: {
          Label("Move Down", systemImage: "arrow.down")
        }
        .labelStyle(.iconOnly)
        .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: 1))
        .accessibilityIdentifier(
          accessibilityIdentifier("moveVideoComponentDownButton-\(layer.id)")
        )

        Button(role: .destructive) {
          removeVideoLayer(id: layer.id)
        } label: {
          Label("Remove from Program", systemImage: "minus")
        }
        .labelStyle(.iconOnly)
        .disabled(!isProgramStructureEditable)
        .accessibilityIdentifier(accessibilityIdentifier("removeVideoComponentButton-\(layer.id)"))
      }
      .buttonStyle(.borderless)

      if layerSupportsDestination(layer) {
        Divider()
        destinationControls(index: index)
      }
    }
    .padding(10)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.background.secondary)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.separator, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .opacity(layer.isMuted ? 0.45 : 1)
    .accessibilityIdentifier(accessibilityIdentifier("videoComponentRow-\(layer.componentName)"))
  }

  @ViewBuilder
  private func destinationControls(index: Int) -> some View {
    if videoLayers.indices.contains(index),
      layerSupportsDestination(videoLayers[index])
    {
      HStack(alignment: .top, spacing: 12) {
        HStack(spacing: 6) {
          TextField(
            "Pos X (px)",
            value: layerDestinationBinding(index: index, keyPath: \.destinationX),
            format: .number.precision(.fractionLength(0))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          TextField(
            "Pos Y (px)",
            value: layerDestinationBinding(index: index, keyPath: \.destinationY),
            format: .number.precision(.fractionLength(0))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))

        HStack(spacing: 6) {
          TextField(
            "Scale X",
            value: layerDestinationBinding(index: index, keyPath: \.destinationScaleX),
            format: .number.precision(.fractionLength(2))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          TextField(
            "Scale Y",
            value: layerDestinationBinding(index: index, keyPath: \.destinationScaleY),
            format: .number.precision(.fractionLength(2))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
      }
      .font(.callout)
    }
  }

  private func layerDestinationBinding(
    index: Int,
    keyPath: WritableKeyPath<VideoLayerPreference, Float>
  ) -> Binding<Float> {
    Binding(
      get: { videoLayers[index][keyPath: keyPath] },
      set: { value in
        updateVideoLayers { $0[index][keyPath: keyPath] = value }
        applyVideoLayerPreferencesToWorkingComposite()
      }
    )
  }

  private func setVideoLayerMuted(_ muted: Bool, at index: Int) {
    guard videoLayers.indices.contains(index) else { return }
    updateVideoLayers { $0[index].isMuted = muted }
  }

  private var availableWorkspaceVideoComponents: [WorkspaceVideoComponentRecord] {
    let usedNames = Set(videoLayers.map(\.componentName))
    return workspaceVideoComponents.filter { !usedNames.contains($0.name) }
  }

  private var availableVideoInputDevices: [WorkspaceInputDeviceRecord] {
    let usedNames = Set(videoLayers.map(\.componentName))
    return workspaceInputDevices.filter { $0.kind == .video && !usedNames.contains($0.name) }
  }

  private var isProgramStructureEditable: Bool {
    windowState.mode == .edit && !windowState.isOperationLocked
  }

  private func addWorkspaceVideoComponent(_ resource: WorkspaceVideoComponentRecord) {
    guard !videoLayers.contains(where: { $0.componentName == resource.name }) else { return }
    updateVideoLayers { $0.append(VideoLayerPreference(componentName: resource.name)) }
    let step = CompositeProgramStep(
      displayName: resource.name,
      component: resource.component
    )
    compositeProgramDefinition.steps.append(step)
    applyVideoLayerPreferencesToWorkingComposite()
  }

  private func addVideoInputDevice(_ device: WorkspaceInputDeviceRecord) {
    guard !videoLayers.contains(where: { $0.componentName == device.name }) else { return }
    updateVideoLayers { $0.append(VideoLayerPreference(componentName: device.name)) }
    compositeProgramDefinition.steps.append(
      CompositeProgramStep(
        displayName: device.name,
        component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: device.id))
      )
    )
    applyVideoLayerPreferencesToWorkingComposite()
  }

  private func canMoveCompositeStep(index: Int, offset: Int) -> Bool {
    guard videoLayers.indices.contains(index) else { return false }
    return videoLayers.indices.contains(index + offset)
  }

  private func moveCompositeStep(index: Int, offset: Int) {
    guard videoLayers.indices.contains(index) else { return }
    let destination = index + offset
    guard videoLayers.indices.contains(destination) else { return }
    updateVideoLayers { $0.swapAt(index, destination) }
    applyVideoLayerPreferencesToWorkingComposite()
  }

  private func removeVideoLayer(id: String) {
    updateVideoLayers { $0.removeAll { $0.id == id } }
    compositeProgramDefinition.steps.removeAll { $0.id == id }
  }

  private func componentDefinition(named name: String) -> ProgramComponentDefinition? {
    workspaceVideoComponents.first(where: { $0.name == name })?.component.definition
  }

  private func videoLayerSystemImage(named name: String) -> String {
    if workspaceInputDevices.contains(where: { $0.name == name }) {
      return "video"
    }
    return componentDefinition(named: name)?.videoComponentSystemImage ?? "square.stack"
  }

  private func layerSupportsDestination(_ layer: VideoLayerPreference) -> Bool {
    VideoLayerDestinationPolicy.supportsDestination(
      layerName: layer.componentName,
      inputDevices: workspaceInputDevices,
      videoComponents: workspaceVideoComponents
    )
  }

  private func applyVideoLayerPreferencesToWorkingComposite() {
    compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
      workspaceVideoComponents,
      layers: videoLayers,
      to: compositeProgramDefinition,
      coordinateWidth: coordinateWidth,
      coordinateHeight: coordinateHeight
    )
  }

  private var videoLayerProgramName: String {
    selectedProgramDefinitionName ?? selectedProgramDefinitionRecord?.name ?? "New Program"
  }

  private var videoLayers: [VideoLayerPreference] {
    programPreferences.videoLayers(forProgramNamed: videoLayerProgramName)
  }

  private func updateVideoLayers(_ mutation: (inout [VideoLayerPreference]) -> Void) {
    var layers = videoLayers
    mutation(&layers)
    programPreferences.setVideoLayers(layers, forProgramNamed: videoLayerProgramName)
  }

  private func videoLayerBinding(id: String) -> Binding<VideoLayerPreference>? {
    guard videoLayers.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: {
        videoLayers.first(where: { $0.id == id })
          ?? VideoLayerPreference(componentName: id)
      },
      set: { newValue in
        updateVideoLayers { layers in
          guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
          layers[index] = newValue
        }
        applyVideoLayerPreferencesToWorkingComposite()
      }
    )
  }

  private func presentPlacementEditor(for layer: VideoLayerPreference) {
    guard let binding = videoLayerBinding(id: layer.id) else { return }
    let selection = VideoLayerPlacementEditorSelection(
      id: layer.id,
      layer: binding,
      coordinateWidth: coordinateWidth,
      coordinateHeight: coordinateHeight,
      applyChanges: applyVideoLayerPreferencesToWorkingComposite
    )
    if let placementEditorPresenter {
      placementEditorPresenter(selection)
    } else {
      placementEditorSelection = selection
    }
  }

  private func accessibilityIdentifier(_ identifier: String) -> String {
    accessibilityIdentifierPrefix.isEmpty
      ? identifier : "\(accessibilityIdentifierPrefix)-\(identifier)"
  }
}

struct VideoLayerPlacementEditorSelection: Identifiable {
  var id: String
  var layer: Binding<VideoLayerPreference>
  var coordinateWidth: Float
  var coordinateHeight: Float
  var applyChanges: () -> Void
}

private struct VideoLayerPlacementEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var layer: VideoLayerPreference
  var coordinateWidth: Float
  var coordinateHeight: Float
  var applyChanges: () -> Void
  @State private var dragStart: CGPoint?
  @State private var resizeStart: CGSize?

  init(selection: VideoLayerPlacementEditorSelection) {
    _layer = selection.layer
    coordinateWidth = selection.coordinateWidth
    coordinateHeight = selection.coordinateHeight
    applyChanges = selection.applyChanges
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Edit Placement")
            .font(.headline)
          Text(layer.componentName)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }

      placementCanvas

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          Text("Pos").frame(width: 42, alignment: .leading)
          Text("X").foregroundStyle(.secondary)
          TextField(
            "Value (px)",
            value: valueBinding(\.destinationX),
            format: .number.precision(.fractionLength(0))
          )
          Text("Y").foregroundStyle(.secondary)
          TextField(
            "Value (px)",
            value: valueBinding(\.destinationY),
            format: .number.precision(.fractionLength(0))
          )
        }
        GridRow {
          Text("Scale").frame(width: 42, alignment: .leading)
          Text("X").foregroundStyle(.secondary)
          TextField(
            "Value (x)",
            value: valueBinding(\.destinationScaleX),
            format: .number.precision(.fractionLength(2))
          )
          Text("Y").foregroundStyle(.secondary)
          TextField(
            "Value (x)",
            value: valueBinding(\.destinationScaleY),
            format: .number.precision(.fractionLength(2))
          )
        }
      }

      HStack {
        Button("Reset") {
          layer.destinationX = 0
          layer.destinationY = 0
          layer.destinationScaleX = 1
          layer.destinationScaleY = 1
          applyChanges()
        }
        Spacer()
        Text("Drag to move. Drag the lower-right handle to resize.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .frame(minWidth: 680, minHeight: 560)
    .accessibilityIdentifier("videoLayerPlacementEditor")
  }

  private var placementCanvas: some View {
    GeometryReader { proxy in
      let canvasSize = fittedCanvasSize(in: proxy.size)
      let origin = CGPoint(
        x: (proxy.size.width - canvasSize.width) / 2,
        y: (proxy.size.height - canvasSize.height) / 2
      )
      let xRatio = canvasSize.width / CGFloat(max(coordinateWidth, 1))
      let yRatio = canvasSize.height / CGFloat(max(coordinateHeight, 1))
      let layerOrigin = CGPoint(
        x: origin.x + CGFloat(layer.destinationX) * xRatio,
        y: origin.y + CGFloat(layer.destinationY) * yRatio
      )
      let layerSize = CGSize(
        width: max(canvasSize.width * CGFloat(layer.destinationScaleX), 12),
        height: max(canvasSize.height * CGFloat(layer.destinationScaleY), 12)
      )

      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(.black)
          .overlay { gridOverlay }
          .frame(width: canvasSize.width, height: canvasSize.height)
          .position(x: origin.x + canvasSize.width / 2, y: origin.y + canvasSize.height / 2)

        ZStack(alignment: .bottomTrailing) {
          Rectangle()
            .fill(Color.accentColor.opacity(0.18))
            .overlay {
              Rectangle().stroke(Color.accentColor, lineWidth: 2)
            }
            .overlay {
              Text(layer.componentName)
                .lineLimit(1)
                .padding(6)
                .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
            .gesture(moveGesture(xRatio: xRatio, yRatio: yRatio))

          Circle()
            .fill(Color.accentColor)
            .stroke(.white, lineWidth: 2)
            .frame(width: 14, height: 14)
            .offset(x: 7, y: 7)
            .gesture(resizeGesture(canvasSize: canvasSize))
        }
        .frame(width: layerSize.width, height: layerSize.height)
        .position(
          x: layerOrigin.x + layerSize.width / 2,
          y: layerOrigin.y + layerSize.height / 2
        )
      }
      .clipped()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
  }

  private var gridOverlay: some View {
    Canvas { context, size in
      var path = Path()
      for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
        path.move(to: CGPoint(x: size.width * fraction, y: 0))
        path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
        path.move(to: CGPoint(x: 0, y: size.height * fraction))
        path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
      }
      context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
    }
  }

  private func fittedCanvasSize(in available: CGSize) -> CGSize {
    let aspect = CGFloat(max(coordinateWidth, 1) / max(coordinateHeight, 1))
    let availableAspect = available.width / max(available.height, 1)
    if availableAspect > aspect {
      return CGSize(width: available.height * aspect, height: available.height)
    }
    return CGSize(width: available.width, height: available.width / aspect)
  }

  private func moveGesture(xRatio: CGFloat, yRatio: CGFloat) -> some Gesture {
    DragGesture()
      .onChanged { value in
        if dragStart == nil {
          dragStart = CGPoint(x: CGFloat(layer.destinationX), y: CGFloat(layer.destinationY))
        }
        guard let dragStart else { return }
        layer.destinationX = Float(dragStart.x + value.translation.width / xRatio)
        layer.destinationY = Float(dragStart.y + value.translation.height / yRatio)
        applyChanges()
      }
      .onEnded { _ in dragStart = nil }
  }

  private func resizeGesture(canvasSize: CGSize) -> some Gesture {
    DragGesture()
      .onChanged { value in
        if resizeStart == nil {
          resizeStart = CGSize(
            width: CGFloat(layer.destinationScaleX),
            height: CGFloat(layer.destinationScaleY)
          )
        }
        guard let resizeStart else { return }
        layer.destinationScaleX = Float(
          max(resizeStart.width + value.translation.width / canvasSize.width, 0.01))
        layer.destinationScaleY = Float(
          max(resizeStart.height + value.translation.height / canvasSize.height, 0.01))
        applyChanges()
      }
      .onEnded { _ in resizeStart = nil }
  }

  private func valueBinding(_ keyPath: WritableKeyPath<VideoLayerPreference, Float>) -> Binding<
    Float
  > {
    Binding(
      get: { layer[keyPath: keyPath] },
      set: {
        layer[keyPath: keyPath] = $0
        applyChanges()
      }
    )
  }
}

struct CanvasVideoLayersDetailPane: View {
  @State private var landscapePlacementEditorSelection: VideoLayerPlacementEditorSelection?
  @State private var portraitPlacementEditorSelection: VideoLayerPlacementEditorSelection?
  var selectedProgramDefinitionName: String?
  @Binding var landscapeCompositeProgramDefinition: CompositeProgramDefinition
  @Binding var landscapeProgramPreferences: ProgramPreferences
  @Binding var portraitCompositeProgramDefinition: CompositeProgramDefinition
  @Binding var portraitProgramPreferences: ProgramPreferences
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var landscapeCoordinateWidth: Float
  var landscapeCoordinateHeight: Float
  var portraitCoordinateWidth: Float
  var portraitCoordinateHeight: Float
  var windowState: WorkspaceWindowState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Video Layers")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 16)

      Form {
        Section {
          landscapeEditor.videoComponentControls
        } header: {
          Text("Landscape Layers")
        }

        Section {
          portraitEditor.videoComponentControls
        } header: {
          Text("Portrait Layers")
        }
      }
      .formStyle(.grouped)
    }
    .sheet(item: $landscapePlacementEditorSelection) { selection in
      VideoLayerPlacementEditor(selection: selection)
    }
    .sheet(item: $portraitPlacementEditorSelection) { selection in
      VideoLayerPlacementEditor(selection: selection)
    }
    .accessibilityIdentifier("canvasVideoLayersDetailPane")
  }

  private var landscapeEditor: VideoLayersDetailPane {
    VideoLayersDetailPane(
      selectedProgramDefinitionName: selectedProgramDefinitionName,
      selectedProgramDefinitionRecord: nil,
      compositeProgramDefinition: $landscapeCompositeProgramDefinition,
      programPreferences: $landscapeProgramPreferences,
      workspaceInputDevices: workspaceInputDevices,
      workspaceVideoComponents: workspaceVideoComponents,
      coordinateWidth: landscapeCoordinateWidth,
      coordinateHeight: landscapeCoordinateHeight,
      windowState: windowState,
      accessibilityIdentifierPrefix: "landscape",
      placementEditorPresenter: { landscapePlacementEditorSelection = $0 }
    )
  }

  private var portraitEditor: VideoLayersDetailPane {
    VideoLayersDetailPane(
      selectedProgramDefinitionName: selectedProgramDefinitionName,
      selectedProgramDefinitionRecord: nil,
      compositeProgramDefinition: $portraitCompositeProgramDefinition,
      programPreferences: $portraitProgramPreferences,
      workspaceInputDevices: workspaceInputDevices,
      workspaceVideoComponents: workspaceVideoComponents,
      coordinateWidth: portraitCoordinateWidth,
      coordinateHeight: portraitCoordinateHeight,
      windowState: windowState,
      accessibilityIdentifierPrefix: "portrait",
      placementEditorPresenter: { portraitPlacementEditorSelection = $0 }
    )
  }
}

enum VideoLayerDestinationPolicy {
  static func supportsDestination(
    layerName: String,
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord]
  ) -> Bool {
    if inputDevices.contains(where: { $0.kind == .video && $0.name == layerName }) {
      return true
    }
    return switch videoComponents.first(where: { $0.name == layerName })?.component.definition {
    case .inputCameraDevice, .clock:
      true
    case .fillSolidColor, .fillLinearGradient, .fillRadialGradient, .fillConicGradient,
      .testPattern, .none:
      false
    }
  }
}

extension ProgramComponentDefinition {
  fileprivate var videoComponentSystemImage: String {
    switch self {
    case .inputCameraDevice:
      return "video"
    case .fillSolidColor:
      return "square"
    case .fillLinearGradient:
      return "circle.lefthalf.filled"
    case .fillRadialGradient:
      return "circle.righthalf.filled"
    case .fillConicGradient:
      return "circle.bottomhalf.filled"
    case .clock:
      return "clock"
    case .testPattern:
      return "checkerboard.rectangle"
    }
  }
}

#if DEBUG
  #Preview("Video Layers - Landscape") {
    VideoLayersDetailPanePreviewHost()
      .frame(width: 360, height: 720)
  }

  #Preview("Video Layers - Narrow Inspector") {
    VideoLayersDetailPanePreviewHost()
      .frame(width: 280, height: 720)
  }

  #Preview("Video Layers - Empty") {
    VideoLayersDetailPanePreviewHost(isEmpty: true)
      .frame(width: 360, height: 420)
  }

  #Preview("Video Layers - Landscape and Portrait") {
    CanvasVideoLayersDetailPanePreviewHost()
      .frame(width: 360, height: 820)
  }

  @MainActor
  private struct VideoLayersDetailPanePreviewHost: View {
    @State private var compositeProgramDefinition: CompositeProgramDefinition
    @State private var programPreferences: ProgramPreferences

    init(isEmpty: Bool = false) {
      _compositeProgramDefinition = State(
        initialValue: LDTXAppUIPreviewFixtures.compositeProgramDefinition
      )
      _programPreferences = State(
        initialValue: makeVideoLayerPreviewPreferences(isEmpty: isEmpty)
      )
    }

    var body: some View {
      VideoLayersDetailPane(
        selectedProgramDefinitionName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
        selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
        compositeProgramDefinition: $compositeProgramDefinition,
        programPreferences: $programPreferences,
        workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
        workspaceVideoComponents: videoLayerPreviewComponents,
        windowState: videoLayerPreviewWindowState
      )
    }
  }

  @MainActor
  private struct CanvasVideoLayersDetailPanePreviewHost: View {
    @State private var landscapeCompositeProgramDefinition =
      LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var landscapeProgramPreferences = makeVideoLayerPreviewPreferences()
    @State private var portraitCompositeProgramDefinition =
      LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var portraitProgramPreferences = makeVideoLayerPreviewPreferences(
      destinationX: 54,
      destinationY: 160
    )

    var body: some View {
      CanvasVideoLayersDetailPane(
        selectedProgramDefinitionName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
        landscapeCompositeProgramDefinition: $landscapeCompositeProgramDefinition,
        landscapeProgramPreferences: $landscapeProgramPreferences,
        portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
        portraitProgramPreferences: $portraitProgramPreferences,
        workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
        workspaceVideoComponents: videoLayerPreviewComponents,
        landscapeCoordinateWidth: 1_920,
        landscapeCoordinateHeight: 1_080,
        portraitCoordinateWidth: 1_080,
        portraitCoordinateHeight: 1_920,
        windowState: videoLayerPreviewWindowState
      )
    }
  }

  @MainActor
  private func makeVideoLayerPreviewPreferences(
    isEmpty: Bool = false,
    destinationX: Float = 96,
    destinationY: Float = 72
  ) -> ProgramPreferences {
    var preferences = LDTXAppUIPreviewFixtures.programPreferences
    guard !isEmpty else { return preferences }
    preferences.setVideoLayers(
      [
        VideoLayerPreference(
          componentName: "Desk Camera",
          destinationX: destinationX,
          destinationY: destinationY,
          destinationScaleX: 0.72,
          destinationScaleY: 0.72
        ),
        VideoLayerPreference(
          componentName: "Clock",
          destinationX: destinationX + 640,
          destinationY: destinationY + 48,
          destinationScaleX: 1.1,
          destinationScaleY: 0.9
        ),
      ],
      forProgramNamed: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName ?? "Demo Program"
    )
    return preferences
  }

  @MainActor
  private var videoLayerPreviewComponents: [WorkspaceVideoComponentRecord] {
    [
      WorkspaceVideoComponentRecord(
        name: "Clock",
        component: .clock(ClockComponent())
      )
    ]
  }

  private var videoLayerPreviewWindowState: WorkspaceWindowState {
    WorkspaceWindowState(
      mode: .edit,
      outputSessionState: .idle,
      isOperationLocked: false
    )
  }
#endif
