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
  private weak var document: (any WorkspaceDocumentContext)?
  let appletData: WorkspaceAppletData
  let stateService: WorkspaceStateService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private let runtimeWorkspace: () -> WorkspaceV4Bundle?
  private let reportError: (Error) -> Void
  let deviceRegistry: DeviceRegistryService

  let layout = WorkspacePaneLayout()
  let contentPane: WorkspaceContentPane

  let screenshotResultPopover = NSPopover()
  private let toolbarCoordinator: WorkspaceToolbarCoordinator
  private var inferenceTask: Task<Void, Never>?
  private var isClosed = false

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

    toolbarCoordinator = WorkspaceToolbarCoordinator()
    super.init(nibName: nil, bundle: nil)

    let host = NSHostingController(rootView: workspaceView)
    host.sizingOptions = []
    host.sceneBridgingOptions = []
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
    configureToolbar()
    refreshToolbarState()
    observeToolbarState()

  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  public override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.toolbar = toolbarCoordinator.toolbar
    view.window?.toolbarStyle = .unified
    didAttachWindow?(view.window)
  }

  var didAttachWindow: ((NSWindow?) -> Void)?

  @objc func toggleSidebar(_ sender: Any?) {
    stateService.isSidebarVisible.toggle()
  }

  @objc func toggleInspector(_ sender: Any?) {
    stateService.isInspectorVisible.toggle()
  }

  private func configureToolbar() {
    toolbarCoordinator.sidebarItem.label = String(localized: "Toggle Sidebar")
    toolbarCoordinator.sidebarItem.image = NSImage(
      systemSymbolName: "sidebar.left", accessibilityDescription: nil)
    toolbarCoordinator.sidebarItem.target = self
    toolbarCoordinator.sidebarItem.action = #selector(toggleSidebar(_:))
    toolbarCoordinator.sidebarItem.isNavigational = true
    toolbarCoordinator.sidebarItem.autovalidates = false

    toolbarCoordinator.stopOutputItem.label = String(localized: "Stop Output")
    toolbarCoordinator.stopOutputItem.image = NSImage(
      systemSymbolName: "stop.fill", accessibilityDescription: nil)
    toolbarCoordinator.stopOutputItem.target = self
    toolbarCoordinator.stopOutputItem.action = #selector(stopOutput)
    toolbarCoordinator.stopOutputItem.isNavigational = true

    let startOutputLabel = String(localized: "Start Output")
    toolbarCoordinator.startPauseOutputItem.possibleLabels = [
      startOutputLabel,
      String(localized: "Pause Output"),
    ]
    toolbarCoordinator.startPauseOutputItem.label = startOutputLabel
    toolbarCoordinator.startPauseOutputItem.image = NSImage(
      systemSymbolName: "play.fill", accessibilityDescription: nil)
    toolbarCoordinator.startPauseOutputItem.target = self
    toolbarCoordinator.startPauseOutputItem.action = #selector(toggleOutput)
    toolbarCoordinator.startPauseOutputItem.isNavigational = true

    toolbarCoordinator.captureScreenshotsItem.label = String(localized: "Capture Screenshot(s)")
    toolbarCoordinator.captureScreenshotsItem.image = NSImage(
      systemSymbolName: "camera", accessibilityDescription: nil)
    toolbarCoordinator.captureScreenshotsItem.target = self
    toolbarCoordinator.captureScreenshotsItem.action = #selector(captureScreenshots)
    toolbarCoordinator.captureScreenshotsItem.isNavigational = true

    toolbarCoordinator.runInferenceItem.label = String(localized: "Run Inference")
    toolbarCoordinator.runInferenceItem.image = NSImage(
      systemSymbolName: "sparkles", accessibilityDescription: nil)
    toolbarCoordinator.runInferenceItem.target = self
    toolbarCoordinator.runInferenceItem.action = #selector(runInference)

    toolbarCoordinator.toggleInspectorItem.label = String(localized: "Toggle Inspector")
    toolbarCoordinator.toggleInspectorItem.image = NSImage(
      systemSymbolName: "sidebar.right", accessibilityDescription: nil)
    toolbarCoordinator.toggleInspectorItem.target = self
    toolbarCoordinator.toggleInspectorItem.action = #selector(toggleInspector(_:))
    toolbarCoordinator.toggleInspectorItem.autovalidates = false

    toolbarCoordinator.toolbar.autosavesConfiguration = false
    toolbarCoordinator.toolbar.allowsUserCustomization = false
    toolbarCoordinator.toolbar.displayMode = .iconOnly
    toolbarCoordinator.toolbar.delegate = toolbarCoordinator
  }

  private func refreshToolbarState() {
    toolbarCoordinator.startPauseOutputItem.label =
      stateService.recordingState == .recording
      ? String(localized: "Pause Output") : String(localized: "Start Output")
    toolbarCoordinator.startPauseOutputItem.image = NSImage(
      systemSymbolName: stateService.recordingState == .recording ? "pause.fill" : "play.fill",
      accessibilityDescription: nil)

  }

  private var inferenceRequest: (vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, url: URL)? {
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
        refreshToolbarState()
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

    refreshToolbarState()
  }

  private func observeToolbarState() {
    guard !isClosed else { return }
    withObservationTracking {
      refreshToolbarState()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeToolbarState() }
    }
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
      content: WorkspaceContentRepresentation(controller: contentPane),
      inspector: inspectorView,
      inspectorWidthChanged: { [weak self] width in
        self?.toolbarCoordinator.updateInspectorWidth(width)
      })
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
      if !showScreenshotResult(
        title: "Screenshot could not be captured", message: error.localizedDescription)
      {
        reportError(error)
      }
    }
  }

  @discardableResult
  private func showScreenshotResult(
    title: String, message: String, screenshots: [WorkspaceScreenshot] = []
  ) -> Bool {
    screenshotResultPopover.behavior = .transient
    let controller = NSHostingController(
      rootView: ScreenshotResultView(title: title, message: message, screenshots: screenshots))
    controller.sizingOptions = .preferredContentSize
    screenshotResultPopover.contentViewController = controller
    screenshotResultPopover.contentViewController?.view.setAccessibilityLabel(
      "\(title). \(message)")
    toolbarCoordinator.showScreenshotResultPopover(screenshotResultPopover)
    return true
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
    screenshotResultPopover.close()

  }

  @objc func stopOutput() {
    guard stateService.recordingState.canStop else { return }
    Task { await runtimeActions()?.stopOutput() }
  }

  @objc func toggleOutput() {
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

extension WorkspaceViewController: NSToolbarItemValidation {
  public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    guard !isClosed,
      let identifier = WorkspaceToolbarCoordinator.Identifiers(
        rawValue: item.itemIdentifier.rawValue)
    else { return false }
    return switch identifier {
    case .captureScreenshots: true
    case .stopOutput: stateService.recordingState.canStop
    case .startPauseOutput:
      (stateService.recordingState.canStart && document?.fileURL != nil)
        || stateService.recordingState == .recording
    case .runInference:
      inferenceTask == nil && inferenceRequest != nil && runtimeActions() != nil
    default: false
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
        if stateService.isSidebarVisible {
          sidebar.frame(width: sidebarWidth)
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

private struct WorkspaceContentRepresentation: NSViewControllerRepresentable {
  let controller: WorkspaceContentPane

  func makeNSViewController(context: Context) -> WorkspaceContentPane { controller }
  func updateNSViewController(_ controller: WorkspaceContentPane, context: Context) {}

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsViewController: WorkspaceContentPane, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 480, height: proposal.height ?? 560)
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
