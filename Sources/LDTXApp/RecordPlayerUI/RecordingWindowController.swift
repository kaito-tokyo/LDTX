// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import LDTXRecording
import Observation
import SwiftUI

@MainActor
public final class RecordingWindowController: NSWindowController, NSWindowDelegate,
  NSToolbarDelegate
{
  private let model: LDTXRecordPlayerModel
  private let split: PaneSplitViewController
  private var started = false

  public init(
    recordingURL: URL, scenarioFixture: RecordingPreviewScenarioFixture? = nil,
    assetLoader: LDTXRecordPlayerAssetLoader? = nil
  ) {
    model = LDTXRecordPlayerModel(
      recordingURL: recordingURL, scenarioFixture: scenarioFixture,
      assetLoader: assetLoader ?? Self.loadAsset)
    let model = model
    let presentation = RecordingPresentationState()
    split = PaneSplitViewController(
      sidebar: paneHost(
        LDTXRecordPlayerView(
          model: model, presentation: presentation, pane: .sidebar, closePreview: {})),
      content: paneHost(
        LDTXRecordPlayerView(
          model: model, presentation: presentation, pane: .content, closePreview: {})),
      inspector: paneHost(
        LDTXRecordPlayerView(
          model: model, presentation: presentation, pane: .inspector, closePreview: {})),
      sidebarCanCollapse: true, inspectorMaximum: 360)
    let window = PaneWindow(contentViewController: split)
    window.restorationURL = recordingURL
    window.restorationKind = "recording"
    window.isRestorable = false
    window.title = recordingURL.deletingPathExtension().lastPathComponent
    window.setContentSize(NSSize(width: 960, height: 600))
    window.center()
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    split.splitViewItems[0].isCollapsed = true
    let toolbar = NSToolbar(identifier: "RecordingToolbar.AppKit.v1")
    toolbar.delegate = self
    window.toolbar = toolbar
    window.setFrameAutosaveName("Recording.AppKit.v1")
  }

  private static func loadAsset(
    recordingURL: URL, canvas: RecordingCanvas?
  ) async throws -> AVAsset {
    let package = try RecordingPackage(contentsOf: recordingURL)
    let media = canvas.flatMap(package.media(for:))
    let mediaPath = media?.path ?? package.mainMediaPath
    let asset = AVURLAsset(url: media?.url ?? package.mainMediaURL)
    let timeline = try RecordingDASHTimeline(
      contentsOf: recordingURL.appendingPathComponent("manifest.mpd")
    )
    let composition = AVMutableComposition()
    let presentationStart = timeline.presentationStart(for: mediaPath)
    let audioStart = timeline.audioPresentationStart(for: mediaPath) ?? presentationStart

    try await insertFirstTrack(
      from: asset,
      mediaType: .video,
      at: presentationStart,
      into: composition
    )
    try await insertFirstTrack(
      from: asset,
      mediaType: .audio,
      at: audioStart,
      into: composition
    )
    return composition
  }

  private static func insertFirstTrack(
    from asset: AVAsset,
    mediaType: AVMediaType,
    at presentationStart: CMTime?,
    into composition: AVMutableComposition
  ) async throws {
    guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first,
      let destinationTrack = composition.addMutableTrack(
        withMediaType: mediaType,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let timeRange = try await sourceTrack.load(.timeRange)
    try destinationTrack.insertTimeRange(
      timeRange,
      of: sourceTrack,
      at: presentationStart ?? timeRange.start
    )
    if mediaType == .video {
      destinationTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  public override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    if !started {
      started = true
      model.start()
      observeClose()
      observeAlert()
    }
  }
  private func observeClose() {
    let shouldClose = withObservationTracking {
      model.shouldClose
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeClose() }
    }
    if shouldClose { close() }
  }
  private func observeAlert() {
    let pending = withObservationTracking {
      model.alert
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeAlert() }
    }
    guard let pending, let window else { return }
    let alert = NSAlert()
    alert.messageText = pending.title
    alert.informativeText = pending.message
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window) { [weak self] _ in
      self?.model.alert = nil
      if pending.closeAfterDismissal { self?.close() }
    }
  }
  public func windowWillClose(_ notification: Notification) { model.stop() }
  @objc public func toggleInspector(_ sender: Any?) { split.toggleInspector(sender) }
  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .init("inspector")]
  }
  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  public func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = "Inspector"
    item.image = NSImage(
      systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")
    item.target = self
    item.action = #selector(toggleInspector)
    return item
  }
}
