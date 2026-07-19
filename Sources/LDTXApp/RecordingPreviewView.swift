// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
@preconcurrency import AVKit
@preconcurrency import AppKit
import LDTXRecording
import OSLog

private let recordingPreviewLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "RecordingPreview"
)

@MainActor
final class RecordingPreviewWindowManager {
  static let shared = RecordingPreviewWindowManager()

  private var controllers: [URL: RecordingPreviewWindowController] = [:]

  func open(recordingURL: URL) {
    let recordingURL = recordingURL.standardizedFileURL
    if let controller = controllers[recordingURL] {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }

    let controller = RecordingPreviewWindowController(recordingURL: recordingURL)
    controller.onClose = { [weak self] in
      self?.controllers.removeValue(forKey: recordingURL)
    }
    controllers[recordingURL] = controller
    NSApp.activate()
    controller.showWindow(nil)
    controller.window?.center()
    controller.window?.setIsVisible(true)
    controller.window?.makeKeyAndOrderFront(nil)
    controller.window?.orderFrontRegardless()
    recordingPreviewLogger.notice(
      "Opened recording preview window; visible=\(controller.window?.isVisible == true, privacy: .public)."
    )
    controller.start()
  }
}

@MainActor
private final class RecordingPreviewWindowController: NSWindowController, NSWindowDelegate,
  NSToolbarDelegate
{
  var onClose: (() -> Void)?

  private let previewViewController: RecordingPreviewViewController

  init(recordingURL: URL) {
    previewViewController = RecordingPreviewViewController(recordingURL: recordingURL)
    let window = NSWindow(contentViewController: previewViewController)
    window.isReleasedWhenClosed = false
    window.title = recordingURL.deletingPathExtension().lastPathComponent
    window.setContentSize(NSSize(width: 960, height: 600))
    window.minSize = NSSize(width: 640, height: 360)
    window.styleMask.formUnion([.titled, .resizable, .miniaturizable, .closable])

    super.init(window: window)
    window.delegate = self

    let toolbar = NSToolbar(identifier: "RecordingPreviewToolbar")
    toolbar.displayMode = .iconOnly
    toolbar.delegate = self
    window.toolbar = toolbar

    previewViewController.closePreview = { [weak window] in
      window?.close()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func windowWillClose(_ notification: Notification) {
    recordingPreviewLogger.notice("Closing recording preview window.")
    previewViewController.stop()
    onClose?()
  }

  func start() {
    previewViewController.start()
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.audioChannel, .flexibleSpace]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .audioChannel]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard itemIdentifier == .audioChannel else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "Audio Channel"
    item.paletteLabel = "Audio Channel"
    item.view = previewViewController.audioChannelControl
    return item
  }
}

extension NSToolbarItem.Identifier {
  fileprivate static let audioChannel = NSToolbarItem.Identifier("RecordingPreviewAudioChannel")
}

@MainActor
private final class RecordingPreviewViewController: NSViewController, NSTextFieldDelegate {
  let audioChannelControl = NSStackView()
  var closePreview: (() -> Void)?

  private let recordingURL: URL
  private let scenarioFixture: RecordingPreviewScenarioFixture?
  private let playerView = AVPlayerView()
  private let markerField = NSTextField()
  private let markerButton = NSButton()
  private let markerErrorImage = NSImageView()
  private var loadTask: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?
  private var package: RecordingPackage?
  private var player: AVPlayer?
  private var audioTracks: [RecordingAudioTrack] = []
  private var audioChannelButtons: [NSButton] = []
  private var selectedAudioTrackIdentifier: String?
  private var selectionGeneration = 0
  private let isAccessingSecurityScopedResource: Bool

  init(recordingURL: URL) {
    self.recordingURL = recordingURL
    scenarioFixture = LDTXRuntimeMode.recordingPreviewFixture
    isAccessingSecurityScopedResource = recordingURL.startAccessingSecurityScopedResource()
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if isAccessingSecurityScopedResource {
      recordingURL.stopAccessingSecurityScopedResource()
    }
  }

  override func loadView() {
    let rootView = NSView()
    rootView.translatesAutoresizingMaskIntoConstraints = false

    playerView.controlsStyle = .inline
    playerView.videoGravity = .resizeAspect
    playerView.translatesAutoresizingMaskIntoConstraints = false

    markerField.placeholderString = "Add a marker note…"
    markerField.delegate = self
    markerField.target = self
    markerField.action = #selector(addMarker)
    markerField.isEnabled = false
    markerField.translatesAutoresizingMaskIntoConstraints = false

    markerButton.image = NSImage(
      systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Add Marker")
    markerButton.bezelStyle = .accessoryBarAction
    markerButton.isBordered = false
    markerButton.target = self
    markerButton.action = #selector(addMarker)
    markerButton.isEnabled = false
    markerButton.toolTip = "Add marker at the current playback time"

    markerErrorImage.image = NSImage(
      systemSymbolName: "exclamationmark.circle.fill",
      accessibilityDescription: "Marker Error"
    )
    markerErrorImage.contentTintColor = .systemRed
    markerErrorImage.isHidden = true

    let markerBar = NSVisualEffectView()
    markerBar.material = .headerView
    markerBar.blendingMode = .withinWindow
    markerBar.translatesAutoresizingMaskIntoConstraints = false

    let markerStack = NSStackView(views: [markerField, markerErrorImage, markerButton])
    markerStack.orientation = .horizontal
    markerStack.alignment = .centerY
    markerStack.spacing = 8
    markerStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    markerStack.translatesAutoresizingMaskIntoConstraints = false
    markerBar.addSubview(markerStack)

    audioChannelControl.orientation = .horizontal
    audioChannelControl.alignment = .centerY
    audioChannelControl.spacing = 4
    audioChannelControl.setHuggingPriority(.required, for: .horizontal)
    audioChannelControl.setContentCompressionResistancePriority(.required, for: .horizontal)

    rootView.addSubview(playerView)
    rootView.addSubview(markerBar)
    NSLayoutConstraint.activate([
      playerView.topAnchor.constraint(equalTo: rootView.topAnchor),
      playerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      playerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      playerView.bottomAnchor.constraint(equalTo: markerBar.topAnchor),
      markerBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      markerBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      markerBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      markerStack.topAnchor.constraint(equalTo: markerBar.topAnchor),
      markerStack.leadingAnchor.constraint(equalTo: markerBar.leadingAnchor),
      markerStack.trailingAnchor.constraint(equalTo: markerBar.trailingAnchor),
      markerStack.bottomAnchor.constraint(equalTo: markerBar.bottomAnchor),
    ])
    view = rootView
  }

  func start() {
    guard loadTask == nil else { return }
    loadTask = Task { await load() }
  }

  func stop() {
    loadTask?.cancel()
    selectionTask?.cancel()
    player?.pause()
    playerView.player = nil
  }

  func controlTextDidChange(_ notification: Notification) {
    updateMarkerButton()
    markerErrorImage.isHidden = true
  }

  @objc private func addMarker() {
    guard let package, let player else {
      closeAfterInternalError("Marker creation was requested before the recording was loaded.")
      return
    }
    let note = markerField.stringValue
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    do {
      _ = try RecordingMarkerStore(package: package).createMarker(
        at: player.currentTime(),
        note: note
      )
      markerField.stringValue = ""
      markerErrorImage.isHidden = true
      updateMarkerButton()
    } catch {
      markerErrorImage.isHidden = false
      markerErrorImage.toolTip = error.localizedDescription
    }
  }

  @objc private func selectAudioChannel(_ sender: NSButton) {
    let index = sender.tag
    guard audioTracks.indices.contains(index) else {
      closeAfterInternalError("Audio selection requested an unknown track index.")
      return
    }
    let identifier = audioTracks[index].identifier
    guard identifier != selectedAudioTrackIdentifier else {
      sender.state = .on
      return
    }
    selectionTask?.cancel()
    selectionTask = Task { await changeAudioChannel(to: identifier) }
  }

  private func load() async {
    recordingPreviewLogger.info(
      "Loading recording preview for \(self.recordingURL.lastPathComponent, privacy: .public)"
    )
    if await loadScenarioFixtureIfNeeded() { return }

    do {
      let package = try RecordingPackage(contentsOf: recordingURL)
      let composition = try await RecordingRemuxer().makeComposition(package: package)
      guard !Task.isCancelled else { return }

      self.package = package
      audioTracks = package.audioTracks
      selectedAudioTrackIdentifier = package.audioTracks.first?.identifier
      configureAudioChannelControl()

      let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
      self.player = player
      playerView.player = player
      markerField.isEnabled = true
      updateMarkerButton()
      player.play()
    } catch {
      guard !Task.isCancelled else { return }
      recordingPreviewLogger.error(
        "Recording preview load failed: \(error.localizedDescription, privacy: .public)"
      )
      presentError(
        title: "Recording Could Not Be Opened",
        message: error.localizedDescription,
        closeAfterDismissal: true
      )
    }
  }

  private func changeAudioChannel(to identifier: String) async {
    if scenarioFixture == .audioSwitchFailure {
      selectedAudioTrackIdentifier = "main"
      configureAudioChannelControl()
      presentError(
        title: "Audio Channel Could Not Be Changed",
        message: "The scenario fixture could not load the selected audio channel."
      )
      return
    }
    guard let package, let player else {
      closeAfterInternalError("Audio selection was requested before the recording was loaded.")
      return
    }

    let previousIdentifier = selectedAudioTrackIdentifier
    selectedAudioTrackIdentifier = identifier
    configureAudioChannelControl()
    selectionGeneration += 1
    let generation = selectionGeneration
    setAudioChannelControlsEnabled(false)

    do {
      let composition = try await RecordingRemuxer().makeComposition(
        package: package,
        enabledAudioTrackIdentifier: identifier
      )
      guard generation == selectionGeneration, !Task.isCancelled else { return }

      let time = player.currentTime()
      let shouldResumePlayback = player.timeControlStatus == .playing
      player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
      await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
      setAudioChannelControlsEnabled(audioTracks.count > 1)
      if shouldResumePlayback { player.play() }
    } catch {
      guard generation == selectionGeneration, !Task.isCancelled else { return }
      selectedAudioTrackIdentifier = previousIdentifier
      configureAudioChannelControl()
      recordingPreviewLogger.error(
        "Audio channel switch failed: \(error.localizedDescription, privacy: .public)"
      )
      presentError(
        title: "Audio Channel Could Not Be Changed",
        message: error.localizedDescription
      )
    }
  }

  private func configureAudioChannelControl() {
    for button in audioChannelButtons {
      audioChannelControl.removeArrangedSubview(button)
      button.removeFromSuperview()
    }
    audioChannelButtons.removeAll()

    for (index, track) in audioTracks.enumerated() {
      let button = NSButton(
        title: track.name, target: self, action: #selector(selectAudioChannel(_:)))
      button.bezelStyle = .texturedRounded
      button.setButtonType(.toggle)
      button.tag = index
      button.state = track.identifier == selectedAudioTrackIdentifier ? .on : .off
      button.toolTip = "Play \(track.name)"
      button.identifier = NSUserInterfaceItemIdentifier(
        "recordingPreviewAudioChannel-\(track.identifier)"
      )
      button.setAccessibilityIdentifier("recordingPreviewAudioChannel-\(track.identifier)")
      button.setAccessibilityLabel(track.name)
      audioChannelControl.addArrangedSubview(button)
      audioChannelButtons.append(button)
    }
    setAudioChannelControlsEnabled(audioTracks.count > 1)
  }

  private func setAudioChannelControlsEnabled(_ isEnabled: Bool) {
    audioChannelButtons.forEach { $0.isEnabled = isEnabled }
  }

  private func updateMarkerButton() {
    markerButton.isEnabled =
      markerField.isEnabled
      && !markerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func presentError(
    title: String,
    message: String,
    closeAfterDismissal: Bool = false
  ) {
    guard let window = view.window else {
      recordingPreviewLogger.error("Could not present Preview error because its window was absent.")
      closePreview?()
      return
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    recordingPreviewLogger.notice("Presenting recording preview error: \(title, privacy: .public)")
    alert.runModal()
    recordingPreviewLogger.notice("Recording preview error was dismissed.")
    if closeAfterDismissal { closePreview?() }
  }

  private func closeAfterInternalError(_ message: String) {
    recordingPreviewLogger.error("\(message, privacy: .public)")
    closePreview?()
  }

  private func loadScenarioFixtureIfNeeded() async -> Bool {
    guard let scenarioFixture else { return false }
    recordingPreviewLogger.notice(
      "Activating recording preview fixture \(scenarioFixture.rawValue, privacy: .public)"
    )

    switch scenarioFixture {
    case .initialLoadFailure:
      presentError(
        title: "Recording Could Not Be Opened",
        message: "The scenario fixture could not open the recording.",
        closeAfterDismissal: true
      )
    case .audioSwitchFailure:
      let fixtureURL = FileManager.default.temporaryDirectory
      audioTracks = [
        RecordingAudioTrack(
          identifier: "main",
          name: "Main Mix",
          mediaPath: "main.mp4",
          mediaURL: fixtureURL.appendingPathComponent("main.mp4")
        ),
        RecordingAudioTrack(
          identifier: "unavailable",
          name: "Unavailable Channel",
          mediaPath: "unavailable.mp4",
          mediaURL: fixtureURL.appendingPathComponent("unavailable.mp4")
        ),
      ]
      selectedAudioTrackIdentifier = "main"
      configureAudioChannelControl()
    case .internalStateFailure:
      await Task.yield()
      closeAfterInternalError("The internal-state-failure scenario fixture was activated.")
    }
    return true
  }
}
