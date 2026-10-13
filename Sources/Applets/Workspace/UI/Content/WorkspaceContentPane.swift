// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime

private let kBelowDividerDragPriority0 = NSLayoutConstraint.Priority(250)
private let kBelowDividerDragPriority10 = NSLayoutConstraint.Priority(260)

public final class WorkspaceContentPane: NSViewController {
  let appletData: WorkspaceAppletData
  let stateService: WorkspaceStateService

  let splitView = NSSplitView()
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
    view = splitView

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

    // MARK: Configures Split View
    splitView.isVertical = false
    splitView.dividerStyle = .thin
    splitView.addArrangedSubview(pairedPreview)
    splitView.addArrangedSubview(editorScrollView)
    splitView.setHoldingPriority(kBelowDividerDragPriority10, forSubviewAt: 0)
    splitView.setHoldingPriority(kBelowDividerDragPriority0, forSubviewAt: 1)

    // MARK: Configures constraints for Editor Stack size
    NSLayoutConstraint.activate([
      masterVolumeEditor.view.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
      audioMixEditor.view.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
      videoLayersEditorTabs.view.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
      videoLayersEditorTabs.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
    ])
    let editorSize = editorStack.fittingSize

    // MARK: Configures remaining constraints
    NSLayoutConstraint.activate([
      splitView.widthAnchor.constraint(greaterThanOrEqualToConstant: editorSize.width),
      editorStack.leadingAnchor.constraint(equalTo: editorScrollView.contentView.leadingAnchor),
      editorStack.topAnchor.constraint(equalTo: editorScrollView.contentView.topAnchor),
      editorStack.widthAnchor.constraint(equalTo: editorScrollView.contentView.widthAnchor),
    ])
  }

  public func configureAfterEstablished() {
    splitView.layoutSubtreeIfNeeded()
    splitView.setPosition(280, ofDividerAt: 0)
    splitView.autosaveName = stateService.externalID.map { "WorkspaceContentPane.\($0)" }
  }



  private final class FlipedStackView: NSStackView {
    override var isFlipped: Bool { true }
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
