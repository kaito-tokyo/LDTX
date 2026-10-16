// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXCapture
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import LDTXYouTubeRTMPS
import Observation
import QuickLookThumbnailing
import SwiftUI

@MainActor @Observable
public final class WorkspaceViewState {
  weak var document: (any WorkspaceDocumentContext)?
  let appletData: WorkspaceAppletData
  let stateService: WorkspaceStateService
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  fileprivate let runtimeWorkspace: () -> WorkspaceV4Bundle?
  fileprivate let reportError: (Error) -> Void
  let deviceRegistry: DeviceRegistryService

  let layout = WorkspacePaneLayout()
  let contentPane: WorkspaceContentPane

  let presentation = WorkspacePresentation()
  @ObservationIgnored private var inferenceTask: Task<Void, Never>?
  private(set) var isClosed = false

  init(
    document: any WorkspaceDocumentContext,
    appletData: WorkspaceAppletData,
    stateService: WorkspaceStateService,
    peakMeter: ProgramAudioPeakMeter,
    reportError: @escaping (Error) -> Void,
    deviceRegistry: DeviceRegistryService,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil },
    runtimeWorkspace: (() -> WorkspaceV4Bundle?)? = nil
  ) {
    self.document = document
    self.appletData = appletData
    self.stateService = stateService
    self.runtimeActions = runtimeActions
    self.runtimeWorkspace = runtimeWorkspace ?? { [weak document] in document?.runtimeWorkspace }
    self.reportError = reportError
    self.deviceRegistry = deviceRegistry

    self.contentPane = WorkspaceContentPane(
      stateService: stateService, appletData: appletData, peakMeter: peakMeter,
      reportError: reportError, pairedPreview: pairedPreview,
      runtimeActions: runtimeActions)

  }

  var didAttachWindow: ((NSWindow?) -> Void)?

  func toggleSidebar() {
    stateService.isSidebarVisible.toggle()
  }

  func toggleInspector() {
    stateService.isInspectorVisible.toggle()
  }

  var inferenceRequest: (vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, url: URL)? {
    guard stateService.inspectorSelector?.kind == .ldtxSceneDetectorVision,
      let workspace = runtimeWorkspace(),
      document?.fileURL != nil,
      let id = stateService.inspectorSelector?.internalID,
      let vision = workspace.definition.visions.compactMap({
        wrapper -> Ldtx_Workspace_V4_LdtxSceneDetectorVision? in
        if case .ldtxSceneDetectorVision(let vision)? = wrapper.vision,
          vision.internalID == id
        {
          return vision
        }
        return nil
      }).first,
      vision.modelInternalID > 0,
      stateService.workspaceDefinition.visions.contains(where: {
        $0.vision == .ldtxSceneDetectorVision(vision)
      }),
      workspace.definition.videoComponents.contains(where: {
        $0.internalID == vision.videoComponentInternalID && $0.canBeVisionInput
          && $0.renderingSize != nil
      })
    else { return nil }
    guard let url = workspace.visionModels[vision.modelInternalID] else { return nil }
    return (vision, url)
  }

  func runInference() {
    guard !isClosed, inferenceTask == nil, let request = inferenceRequest,
      let actions = runtimeActions()
    else { return }
    let id = request.vision.internalID
    let editingVision = stateService.workspaceDefinition.visions.first { $0.internalID == id }
    stateService.visionResults.removeValue(forKey: id)
    stateService.visionFailureMessages.removeValue(forKey: id)
    inferenceTask = Task { [weak self] in
      guard let self else { return }
      defer {
        inferenceTask = nil
        presentation.isInferring = false
      }
      do {
        let result = try await actions.classify(vision: request.vision, modelURL: request.url)
        guard !isClosed, let current = inferenceRequest,
          stateService.workspaceDefinition.visions.first(where: { $0.internalID == id })
            == editingVision,
          current.vision == request.vision, current.url == request.url
        else { return }
        stateService.visionResults[id] = result
      } catch {
        guard !isClosed, let current = inferenceRequest,
          stateService.workspaceDefinition.visions.first(where: { $0.internalID == id })
            == editingVision,
          current.vision == request.vision, current.url == request.url
        else { return }
        stateService.visionFailureMessages[id] = error.localizedDescription
      }
    }

    presentation.isInferring = true
  }

  func captureScreenshots() {
    guard !isClosed else { return }
    do {
      guard let runtimeActions = runtimeActions() else {
        throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
      }
      let files = try runtimeActions.captureScreenshots()
      let programFiles = files.filter { $0.programCanvas != nil }
      showScreenshotResult(
        title: "Screenshots saved",
        message: programFiles.isEmpty
          ? "No Program screenshots were available."
          : programFiles.count == 1
            ? "Saved 1 Program screenshot." : "Saved \(programFiles.count) Program screenshots.",
        screenshots: programFiles.filter { $0.programCanvas == .landscape })
    } catch {
      showScreenshotResult(
        title: "Screenshot could not be captured", message: error.localizedDescription)
    }
  }

  private func showScreenshotResult(
    title: String, message: String, screenshots: [WorkspaceScreenshot] = []
  ) {
    presentation.screenshot = WorkspaceScreenshotPresentation(
      title: title, message: message, screenshots: screenshots)
  }

  func waitForInference() async {
    await inferenceTask?.value
  }

  func tearDown() {
    isClosed = true
    presentation.screenshot = nil

  }

  func stopOutput() {
    guard !isClosed, stateService.recordingState.canStop else { return }
    Task { await runtimeActions()?.stopOutput() }
  }

  func toggleOutput() {
    guard !isClosed else { return }
    let state = stateService.recordingState
    guard (state.canStart && document?.fileURL != nil) || state == .recording else { return }
    Task {
      if state == .recording {
        await runtimeActions()?.pauseOutput()
      } else {
        do {
          guard let runtimeActions = runtimeActions() else {
            throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
          }
          try await runtimeActions.startOutput()
        } catch {
          stateService.outputFailureMessage = error.localizedDescription
        }
      }
    }
  }

}

@MainActor @Observable
final class WorkspacePaneLayout {
  var sidebarWidth: CGFloat = 240
  var inspectorWidth: CGFloat = 320
}

struct WorkspaceView<Sidebar: View, Content: View, Inspector: View>: View {
  let layout: WorkspacePaneLayout
  let stateService: WorkspaceStateService
  let sidebar: Sidebar
  let content: Content
  let inspector: Inspector
  var inspectorWidthChanged: (CGFloat) -> Void = { _ in }

  var body: some View {
    GeometryReader { geometry in
      let dividers =
        (stateService.isSidebarVisible ? 1.0 : 0) + (stateService.isInspectorVisible ? 1 : 0)
      let available = max(0, geometry.size.width - 480 - dividers)
      let inspectorWidth =
        stateService.isInspectorVisible
        ? min(
          layout.inspectorWidth, max(240, available - (stateService.isSidebarVisible ? 200 : 0)))
        : 0
      let sidebarWidth =
        stateService.isSidebarVisible
        ? min(layout.sidebarWidth, max(200, available - inspectorWidth)) : 0
      HStack(spacing: 0) {
        sidebar
          .frame(width: stateService.isSidebarVisible ? sidebarWidth : layout.sidebarWidth)
          .frame(width: sidebarWidth, alignment: .leading)
          .clipped()
          .opacity(stateService.isSidebarVisible ? 1 : 0)
          .allowsHitTesting(stateService.isSidebarVisible)
          .disabled(!stateService.isSidebarVisible)
          .accessibilityHidden(!stateService.isSidebarVisible)
        if stateService.isSidebarVisible {
          WorkspacePaneDivider(
            title: "Sidebar width", width: sidebarWidth,
            maximum: max(200, available - inspectorWidth),
            minimum: 200, isTrailing: false
          ) { layout.sidebarWidth = $0 }
        }
        content.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        if stateService.isInspectorVisible {
          WorkspacePaneDivider(
            title: "Inspector width", width: inspectorWidth,
            maximum: min(480, max(240, available - sidebarWidth)),
            minimum: 240, isTrailing: true
          ) { layout.inspectorWidth = $0 }
        }
        inspector
          .frame(width: stateService.isInspectorVisible ? inspectorWidth : layout.inspectorWidth)
          .frame(width: inspectorWidth, alignment: .trailing)
          .clipped()
          .opacity(stateService.isInspectorVisible ? 1 : 0)
          .allowsHitTesting(stateService.isInspectorVisible)
          .disabled(!stateService.isInspectorVisible)
          .accessibilityHidden(!stateService.isInspectorVisible)
      }
      .onChange(of: inspectorWidth, initial: true) { _, width in
        inspectorWidthChanged(width)
      }
    }
    .coordinateSpace(name: "WorkspacePanes")
    .frame(minWidth: stateService.minimumWindowWidth, minHeight: 400)
  }
}

private struct WorkspacePaneDivider: View {
  let title: LocalizedStringKey
  let width: CGFloat
  let maximum: CGFloat
  let minimum: CGFloat
  let isTrailing: Bool
  let resize: (CGFloat) -> Void
  @State private var dragStart: CGFloat?

  private func adjust(to value: CGFloat) {
    resize(min(maximum, max(minimum, value)))
  }

  var body: some View {
    Divider()
      .overlay {
        Color.clear
          .frame(width: 9)
          .contentShape(Rectangle())
          .pointerStyle(.columnResize)
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("WorkspacePanes"))
              .onChanged { value in
                if dragStart == nil { dragStart = width }
                adjust(to: (dragStart ?? width) + value.translation.width * (isTrailing ? -1 : 1))
              }
              .onEnded { _ in dragStart = nil }
          )
          .accessibilityLabel(title)
          .accessibilityValue(Text("\(Int(width)) points"))
          .accessibilityAdjustableAction { direction in
            adjust(to: width + (direction == .increment ? 20 : -20))
          }
      }
  }
}

struct ScreenshotResultView: View {
  let title: String
  let message: String
  let screenshots: [WorkspaceScreenshot]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(message)
      ForEach(screenshots, id: \.url) { screenshot in
        Button {
          NSWorkspace.shared.open(screenshot.url)
        } label: {
          HStack(spacing: 10) {
            FileIcon(url: screenshot.url)
            Text(screenshot.url.lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(screenshot.url.path)
        .onDrag { NSItemProvider(object: screenshot.url as NSURL) }
      }
    }
    .padding()
    .frame(width: screenshots.isEmpty ? 280 : 360, alignment: .leading)
  }

  private struct FileIcon: View {
    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
      Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .scaledToFit()
        .frame(width: 32, height: 32)
        .task(id: url) {
          image = nil
          let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 32, height: 32), scale: displayScale,
            representationTypes: .all)
          request.iconMode = true
          guard
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
              for: request),
            !Task.isCancelled
          else { return }
          image = representation.nsImage
        }
    }
  }
}

@MainActor @Observable
final class WorkspacePresentation {
  var isInferring = false
  var screenshot: WorkspaceScreenshotPresentation?
}

struct WorkspaceScreenshotPresentation: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let screenshots: [WorkspaceScreenshot]
}

private struct WorkspaceToolbar: ToolbarContent {
  let state: WorkspaceViewState

  var body: some ToolbarContent {
    ToolbarItem(id: "workspace.toggleSidebar", placement: .navigation) {
      Button("Toggle Sidebar", systemImage: "sidebar.left") { state.toggleSidebar() }
        .accessibilityIdentifier("workspace.toggleSidebar")
    }
    ToolbarItem(id: "workspace.stopOutput", placement: .navigation) {
      Button("Stop Output", systemImage: "stop.fill") { state.stopOutput() }
        .disabled(!state.stateService.recordingState.canStop || state.isClosed)
        .accessibilityIdentifier("workspace.stopOutput")
    }
    ToolbarItem(id: "workspace.startPauseOutput", placement: .navigation) {
      Button(
        state.stateService.recordingState == .recording ? "Pause Output" : "Start Output",
        systemImage: state.stateService.recordingState == .recording ? "pause.fill" : "play.fill"
      ) { state.toggleOutput() }
      .disabled(
        state.isClosed
          || !((state.stateService.recordingState.canStart && state.document?.fileURL != nil)
            || state.stateService.recordingState == .recording)
      )
      .accessibilityIdentifier("workspace.startPauseOutput")
    }
    ToolbarItem(id: "workspace.captureScreenshots", placement: .navigation) {
      WorkspaceScreenshotButton(state: state)
    }
    ToolbarItem(id: "workspace.runInference", placement: .primaryAction) {
      Button("Run Inference", systemImage: "sparkles") { state.runInference() }
        .disabled(
          state.presentation.isInferring || state.inferenceRequest == nil
            || state.runtimeActions() == nil || state.isClosed
        )
        .accessibilityIdentifier("workspace.runInference")
    }
    ToolbarItem(id: "workspace.toggleInspector", placement: .primaryAction) {
      Button("Toggle Inspector", systemImage: "sidebar.right") { state.toggleInspector() }
        .accessibilityIdentifier("workspace.toggleInspector")
    }
  }
}

private struct WorkspaceScreenshotButton: View {
  let state: WorkspaceViewState

  var body: some View {
    @Bindable var presentation = state.presentation
    Button("Capture Screenshot(s)", systemImage: "camera") { state.captureScreenshots() }
      .disabled(state.isClosed)
      .accessibilityIdentifier("workspace.captureScreenshots")
      .popover(item: $presentation.screenshot) { result in
        ScreenshotResultView(
          title: result.title, message: result.message, screenshots: result.screenshots)
      }
  }
}

struct WorkspaceRootView: View {
  let state: WorkspaceViewState

  var body: some View {
    WorkspaceView(
      layout: state.layout, stateService: state.stateService,
      sidebar: WorkspaceSidebar(
        stateService: state.stateService, deviceRegistry: state.deviceRegistry,
        appletData: state.appletData, document: state.document, runtimeActions: state.runtimeActions
      ).environment(\.workspaceReportError, state.reportError),
      content: state.contentPane,
      inspector: WorkspaceInspectorContainer(
        deviceRegistry: state.deviceRegistry, stateService: state.stateService,
        appletData: state.appletData, document: state.document,
        runtimeWorkspace: state.runtimeWorkspace, runtimeActions: state.runtimeActions
      ).environment(\.workspaceReportError, state.reportError)
    )
    .toolbar { WorkspaceToolbar(state: state) }
    .background(
      WorkspaceWindowAttachment(state: state)
        .allowsHitTesting(false).accessibilityHidden(true))
  }
}

/// The document window is owned by DocumentGroup. This bridge only attaches runtime
/// error presentation and guards the standard document responder actions.
private struct WorkspaceWindowAttachment: NSViewRepresentable {
  let state: WorkspaceViewState

  func makeNSView(context: Context) -> AttachmentView { AttachmentView(state: state) }
  func updateNSView(_ view: AttachmentView, context: Context) { view.attach() }
  static func dismantleNSView(_ view: AttachmentView, coordinator: ()) { view.detach() }

  final class AttachmentView: NSView {
    private weak var state: WorkspaceViewState?
    private let documentActions: WorkspaceDocumentActions
    private weak var responderHost: NSResponder?

    init(state: WorkspaceViewState) {
      self.state = state
      documentActions = WorkspaceDocumentActions(state: state)
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach()
    }

    func attach() {
      guard let window else {
        detach()
        return
      }
      state?.didAttachWindow?(window)
      let host: NSResponder = window
      guard responderHost !== host else { return }
      detach()
      documentActions.nextResponder = host.nextResponder
      host.nextResponder = documentActions
      responderHost = host
    }

    func detach() {
      if let responderHost, responderHost.nextResponder === documentActions {
        responderHost.nextResponder = documentActions.nextResponder
      }
      responderHost = nil
      documentActions.nextResponder = nil
    }
  }
}

final class WorkspaceDocumentActions: NSResponder, NSUserInterfaceValidations {
  private weak var state: WorkspaceViewState?

  init(state: WorkspaceViewState) {
    self.state = state
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  private var canRevert: Bool {
    state.map { !$0.isClosed && !$0.stateService.isOutputActive } ?? false
  }

  @objc func revertDocumentToSaved(_ sender: Any?) {
    guard canRevert else { return }
    nextResponder?.tryToPerform(#selector(revertDocumentToSaved(_:)), with: sender)
  }
  @objc func browseDocumentVersions(_ sender: Any?) {
    guard canRevert else { return }
    nextResponder?.tryToPerform(#selector(browseDocumentVersions(_:)), with: sender)
  }
  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(revertDocumentToSaved(_:))
      || item.action == #selector(browseDocumentVersions(_:))
    {
      return canRevert
    }
    return true
  }
}
