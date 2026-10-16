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

public final class WorkspaceViewController: NSViewController, NSUserInterfaceValidations {
  weak var document: (any WorkspaceDocumentContext)?
  let appletData: WorkspaceAppletData
  let stateService: WorkspaceStateService
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private let runtimeWorkspace: () -> WorkspaceV4Bundle?
  private let reportError: (Error) -> Void
  let deviceRegistry: DeviceRegistryService

  let layout = WorkspacePaneLayout()
  let contentPane: WorkspaceContentPane

  let presentation = WorkspacePresentation()
  private var inferenceTask: Task<Void, Never>?
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

    super.init(nibName: nil, bundle: nil)

    let host = NSHostingController(rootView: workspaceView)
    host.sizingOptions = []
    host.sceneBridgingOptions = [.toolbars]
    addChild(host)
    view = NSView()
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  public override func viewDidAppear() {
    super.viewDidAppear()
    didAttachWindow?(view.window)
  }

  var didAttachWindow: ((NSWindow?) -> Void)?

  @objc func toggleSidebar(_ sender: Any?) {
    stateService.isSidebarVisible.toggle()
  }

  @objc func toggleInspector(_ sender: Any?) {
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

  @objc func runInference() {
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

  private var sidebarView: some View {
    WorkspaceSidebar(
      stateService: stateService, deviceRegistry: deviceRegistry,
      appletData: appletData, document: document,
      runtimeActions: runtimeActions
    )
    .environment(\.workspaceReportError, reportError)
  }

  private var workspaceView: some View {
    WorkspaceView(
      layout: layout, stateService: stateService,
      sidebar: sidebarView,
      content: contentPane,
      inspector: inspectorView
    )
    .toolbar { [weak self] in
      if let self { WorkspaceToolbar(controller: self) }
    }
  }

  private var inspectorView: some View {
    WorkspaceInspectorContainer(
      deviceRegistry: deviceRegistry,
      stateService: stateService, appletData: appletData, document: document,
      runtimeWorkspace: runtimeWorkspace,
      runtimeActions: runtimeActions
    )
    .environment(\.workspaceReportError, reportError)
  }

  @objc func captureScreenshots() {
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

  @objc func revertDocumentToSaved(_ sender: Any?) {
    guard !isClosed, !stateService.isOutputActive else { return }
    nextResponder?.tryToPerform(#selector(revertDocumentToSaved(_:)), with: sender)
  }

  @objc func browseDocumentVersions(_ sender: Any?) {
    guard !isClosed, !stateService.isOutputActive else { return }
    nextResponder?.tryToPerform(#selector(browseDocumentVersions(_:)), with: sender)
  }

  public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(revertDocumentToSaved(_:))
      || item.action == #selector(browseDocumentVersions(_:))
    {
      return !isClosed && !stateService.isOutputActive
    }
    return true
  }

  func tearDown() {
    isClosed = true
    presentation.screenshot = nil

  }

  @objc func stopOutput() {
    guard !isClosed, stateService.recordingState.canStop else { return }
    Task { await runtimeActions()?.stopOutput() }
  }

  @objc func toggleOutput() {
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
  weak var controller: WorkspaceViewController?

  var body: some ToolbarContent {
    ToolbarItem(id: "workspace.toggleSidebar", placement: .navigation) { [weak controller] in
      if let controller {
        Button("Toggle Sidebar", systemImage: "sidebar.left") { [weak controller] in
          controller?.toggleSidebar(nil)
        }
        .accessibilityIdentifier("workspace.toggleSidebar")
      }
    }
    ToolbarItem(id: "workspace.stopOutput", placement: .navigation) { [weak controller] in
      if let controller {
        Button("Stop Output", systemImage: "stop.fill") { [weak controller] in
          controller?.stopOutput()
        }
        .disabled(!controller.stateService.recordingState.canStop || controller.isClosed)
        .accessibilityIdentifier("workspace.stopOutput")
      }
    }
    ToolbarItem(id: "workspace.startPauseOutput", placement: .navigation) { [weak controller] in
      if let controller {
        Button(
          controller.stateService.recordingState == .recording ? "Pause Output" : "Start Output",
          systemImage: controller.stateService.recordingState == .recording
            ? "pause.fill" : "play.fill"
        ) { [weak controller] in controller?.toggleOutput() }
        .disabled(
          controller.isClosed
            || !((controller.stateService.recordingState.canStart
              && controller.document?.fileURL != nil)
              || controller.stateService.recordingState == .recording)
        )
        .accessibilityIdentifier("workspace.startPauseOutput")
      }
    }
    ToolbarItem(id: "workspace.captureScreenshots", placement: .navigation) { [weak controller] in
      WorkspaceScreenshotButton(controller: controller)
    }
    ToolbarItem(id: "workspace.runInference", placement: .primaryAction) { [weak controller] in
      if let controller {
        Button("Run Inference", systemImage: "sparkles") { [weak controller] in
          controller?.runInference()
        }
        .disabled(
          controller.presentation.isInferring || controller.inferenceRequest == nil
            || controller.runtimeActions() == nil || controller.isClosed
        )
        .accessibilityIdentifier("workspace.runInference")
      }
    }
    ToolbarItem(id: "workspace.toggleInspector", placement: .primaryAction) { [weak controller] in
      if let controller {
        Button("Toggle Inspector", systemImage: "sidebar.right") { [weak controller] in
          controller?.toggleInspector(nil)
        }
        .accessibilityIdentifier("workspace.toggleInspector")
      }
    }
  }
}

private struct WorkspaceScreenshotButton: View {
  weak var controller: WorkspaceViewController?

  var body: some View {
    if let controller {
      @Bindable var presentation = controller.presentation
      Button("Capture Screenshot(s)", systemImage: "camera") { [weak controller] in
        controller?.captureScreenshots()
      }
      .disabled(controller.isClosed)
      .accessibilityIdentifier("workspace.captureScreenshots")
      .popover(item: $presentation.screenshot) { result in
        ScreenshotResultView(
          title: result.title, message: result.message, screenshots: result.screenshots)
      }
    }
  }
}
