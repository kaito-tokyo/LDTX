// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime
import Observation
import SwiftUI

public final class WorkspaceContentPane: NSViewController {
  let appletData: WorkspaceAppletData
  let stateService: WorkspaceStateService

  let layout = WorkspaceContentLayout()
  let pairedPreview: ProgramCanvasPairedPreview
  let editorScrollView = NSScrollView()
  let editorStack: NSStackView = FlipedStackView()
  let masterVolumeEditor: MasterVolumeEditor
  let audioMixEditor: AudioMixEditor
  let videoLayersEditorTabs: NSTabViewController
  let landscapeLayersEditor: VideoLayersEditor
  let landscapeLayersTab: NSTabViewItem
  let portraitLayersEditor: VideoLayersEditor
  let portraitLayersTab: NSTabViewItem

  public init(
    stateService: WorkspaceStateService,
    appletData: WorkspaceAppletData,
    peakMeter: ProgramAudioPeakMeter,
    reportError: @escaping (Error) -> Void,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.pairedPreview = pairedPreview
    self.appletData = appletData
    self.stateService = stateService
    self.videoLayersEditorTabs = NSTabViewController()
    self.masterVolumeEditor = MasterVolumeEditor(
      stateService: stateService, appletData: appletData, peakMeter: peakMeter,
      reportError: reportError, runtimeActions: runtimeActions)
    self.audioMixEditor = AudioMixEditor(
      stateService: stateService, appletData: appletData, peakMeter: peakMeter,
      reportError: reportError, runtimeActions: runtimeActions)
    self.landscapeLayersEditor = VideoLayersEditor(
      stateService: stateService, appletData: appletData, target: .landscape)
    self.landscapeLayersTab = NSTabViewItem(viewController: landscapeLayersEditor)
    self.portraitLayersEditor = VideoLayersEditor(
      stateService: stateService, appletData: appletData, target: .portrait)
    self.portraitLayersTab = NSTabViewItem(viewController: portraitLayersEditor)
    super.init(nibName: nil, bundle: nil)
    videoLayersEditorTabs.addTabViewItem(landscapeLayersTab)
    videoLayersEditorTabs.addTabViewItem(portraitLayersTab)
    addChild(masterVolumeEditor)
    addChild(audioMixEditor)
    addChild(videoLayersEditorTabs)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public override func loadView() {

    // MARK: Configures Paired Preview
    pairedPreview.autoresizingMask = [.width, .height]
    pairedPreview.padding = 12

    // MARK: Configures Video Layers Editor
    landscapeLayersTab.label = "Landscape Video Layers"
    portraitLayersTab.label = "Portrait Video Layers"
    videoLayersEditorTabs.selectedTabViewItemIndex = 0

    // MARK: Configures Editor Pane
    editorStack.orientation = .vertical
    editorStack.alignment = .leading
    editorStack.spacing = 0
    editorStack.addArrangedSubview(masterVolumeEditor.view)
    editorStack.addArrangedSubview(audioMixEditor.view)
    editorStack.addArrangedSubview(videoLayersEditorTabs.view)

    // MARK: Configures Editors
    editorStack.translatesAutoresizingMaskIntoConstraints = false
    editorScrollView.documentView = editorStack
    editorScrollView.hasVerticalScroller = true
    editorScrollView.autohidesScrollers = true
    editorScrollView.autoresizingMask = [.width, .height]

    // MARK: Configures constraints for Editor Stack size
    NSLayoutConstraint.activate([
      masterVolumeEditor.view.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
      audioMixEditor.view.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
      videoLayersEditorTabs.view.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
      videoLayersEditorTabs.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
    ])
    // MARK: Configures remaining constraints
    NSLayoutConstraint.activate([
      editorStack.leadingAnchor.constraint(equalTo: editorScrollView.contentView.leadingAnchor),
      editorStack.topAnchor.constraint(equalTo: editorScrollView.contentView.topAnchor),
      editorStack.widthAnchor.constraint(equalTo: editorScrollView.contentView.widthAnchor),
    ])
    let host = NSHostingController(
      rootView: WorkspaceContentView(
        stateService: stateService, layout: layout,
        preview: pairedPreview, editors: editorScrollView))
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
    configureAfterEstablished()
  }

  public func configureAfterEstablished() {
    layout.restore(externalID: stateService.externalID)
  }

  private final class FlipedStackView: NSStackView {
    override var isFlipped: Bool { true }
  }
}

@MainActor @Observable
final class WorkspaceContentLayout {
  var previewHeight: CGFloat = 280
  private var persistenceKey: String?

  func restore(externalID: String?) {
    let key = externalID.map { "WorkspaceContentPane.\($0).previewHeight" }
    guard key != persistenceKey else { return }
    persistenceKey = key
    previewHeight =
      key.flatMap { UserDefaults.standard.object(forKey: $0) as? Double }
      .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 280
    if let key, UserDefaults.standard.object(forKey: key) == nil,
      let externalID,
      let frames = UserDefaults.standard.stringArray(
        forKey: "NSSplitView Subview Frames WorkspaceContentPane.\(externalID)"),
      let first = frames.first
    {
      let fields = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      if fields.count >= 4, let height = Double(fields[3]), height.isFinite, height >= 0 {
        previewHeight = height
        UserDefaults.standard.set(height, forKey: key)
      }
    }
  }

  func resizePreview(to height: CGFloat) {
    guard height.isFinite else { return }
    previewHeight = max(0, height)
    if let persistenceKey {
      UserDefaults.standard.set(Double(previewHeight), forKey: persistenceKey)
    }
  }
}

private struct WorkspaceContentView: View {
  let stateService: WorkspaceStateService
  let layout: WorkspaceContentLayout
  let preview: ProgramCanvasPairedPreview
  let editors: NSScrollView
  @State private var dragStart: CGFloat?

  var body: some View {
    GeometryReader { geometry in
      let height = min(layout.previewHeight, max(0, geometry.size.height - 1))
      VStack(spacing: 0) {
        WorkspaceNativeView(view: preview)
          .frame(height: height)
        Divider()
          .overlay {
            Color.clear
              .frame(height: 9)
              .contentShape(Rectangle())
              .pointerStyle(.rowResize)
              .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("WorkspaceContent"))
                  .onChanged { value in
                    if dragStart == nil { dragStart = height }
                    layout.resizePreview(
                      to: min(
                        max(0, (dragStart ?? height) + value.translation.height),
                        max(0, geometry.size.height - 1)))
                  }
                  .onEnded { _ in dragStart = nil }
              )
              .accessibilityLabel("Preview height")
              .accessibilityValue(Text("\(Int(height)) points"))
              .accessibilityAdjustableAction { direction in
                layout.resizePreview(
                  to: min(
                    max(0, height + (direction == .increment ? 20 : -20)),
                    max(0, geometry.size.height - 1)))
              }
          }
        WorkspaceNativeView(view: editors)
          .frame(maxHeight: .infinity)
      }
    }
    .coordinateSpace(name: "WorkspaceContent")
    .frame(minWidth: 480, minHeight: 120)
    .onChange(of: stateService.externalID, initial: true) { _, externalID in
      layout.restore(externalID: externalID)
    }
  }
}

private struct WorkspaceNativeView<NativeView: NSView>: NSViewRepresentable {
  let view: NativeView
  func makeNSView(context: Context) -> NativeView { view }
  func updateNSView(_ view: NativeView, context: Context) {}

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NativeView, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 480, height: proposal.height ?? 0)
  }
}

#if DEBUG
  import SwiftUI

  #Preview("Workspace Content", traits: .fixedLayout(width: 480, height: 560)) {
    PreviewWorkspaceContentPaneController(hasProgram: true)
  }

  #Preview("Workspace Content — No Program", traits: .fixedLayout(width: 480, height: 560)) {
    PreviewWorkspaceContentPaneController(hasProgram: false)
  }

#endif
