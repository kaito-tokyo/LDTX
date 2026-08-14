// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AVKit
import AppKit
import LDTXRecording
import OSLog
import Observation
import QuartzCore
import SwiftUI

private let recordingPreviewLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "RecordingPreview"
)

public typealias LDTXRecordPlayerAssetLoader =
  @MainActor @Sendable (URL, RecordingCanvas?) async throws -> AVAsset

public struct LDTXRecordPlayerView: View {
  @State private var model: LDTXRecordPlayerModel
  @State private var pendingMarkerTime: CMTime?
  @State private var pendingTimecodeText = ""
  @State private var markerNote = ""
  @State private var markerError: String?
  @State private var navigationColumnVisibility: NavigationSplitViewVisibility = .detailOnly
  @State private var selectedFeature: PlayerFeature? = .markers
  @State private var isFeatureDetailPresented = true
  @State private var selectedMarkerURL: URL?
  @FocusState private var focusedMarkerField: MarkerField?

  private let closePreview: () -> Void

  public init(
    recordingURL: URL,
    scenarioFixture: RecordingPreviewScenarioFixture? = nil,
    assetLoader: @escaping LDTXRecordPlayerAssetLoader = { recordingURL, canvas in
      let package = try RecordingPackage(contentsOf: recordingURL)
      if let canvas, let media = package.media(for: canvas) {
        return AVURLAsset(url: media.url)
      }
      return AVURLAsset(url: package.mainMediaURL)
    },
    closePreview: @escaping () -> Void = {}
  ) {
    self.closePreview = closePreview
    _model = State(
      initialValue: LDTXRecordPlayerModel(
        recordingURL: recordingURL,
        scenarioFixture: scenarioFixture,
        assetLoader: assetLoader
      )
    )
  }

  public var body: some View {
    @Bindable var model = model

    NavigationSplitView(columnVisibility: $navigationColumnVisibility) {
      featureSidebar
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    } detail: {
      playerContent
        .inspector(isPresented: $isFeatureDetailPresented) {
          featureDetail
            .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
        }
    }
    .frame(minHeight: 360)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isFeatureDetailPresented.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(isFeatureDetailPresented ? "Hide Inspector" : "Show Inspector")
      }
    }
    .task {
      model.start()
    }
    .onDisappear {
      recordingPreviewLogger.notice("Closing recording preview window.")
      model.stop()
    }
    .onChange(of: model.shouldClose) { _, shouldClose in
      if shouldClose { closePreview() }
    }
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK")) {
          if alert.closeAfterDismissal { closePreview() }
        }
      )
    }
  }

  private var featureSidebar: some View {
    List(selection: $selectedFeature) {
      Label("Markers", systemImage: "bookmark")
        .tag(PlayerFeature.markers)
    }
    .listStyle(.sidebar)
    .navigationTitle("Player")
  }

  private var playerContent: some View {
    VStack(spacing: 0) {
      if model.availableCanvases.count > 1 {
        Picker("Canvas", selection: $model.selectedCanvas) {
          ForEach(model.availableCanvases, id: \.self) { canvas in
            Text(canvas == .landscape ? "Landscape" : "Portrait").tag(canvas)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .padding(8)
        .onChange(of: model.selectedCanvas) { _, canvas in
          model.selectCanvas(canvas)
        }
      }
      ZStack {
        LDTXPlaybackPane(
          player: model.player,
          durationSeconds: model.durationSeconds,
          seekRequest: model.playbackSeekRequest
        )

        if model.isLoading {
          ProgressView("Loading Recording…")
            .controlSize(.large)
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
      }
      markerBar
    }
  }

  @ViewBuilder
  private var featureDetail: some View {
    switch selectedFeature {
    case .some(.markers):
      markerList
    case nil:
      ContentUnavailableView(
        "No Feature Selected",
        systemImage: "sidebar.left",
        description: Text("Select a feature in the sidebar.")
      )
    }
  }

  private var markerBar: some View {
    HStack(spacing: 8) {
      TextField("HH:MM:SS.mmm", text: pendingTimecodeBinding)
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.center)
        .foregroundStyle(pendingMarkerTime == nil ? Color.primary : Color.green)
        .frame(width: 116)
        .focused($focusedMarkerField, equals: .timecode)
        .onSubmit(commitPendingTimecode)

      TextField("Add a marker note…", text: $markerNote)
        .focused($focusedMarkerField, equals: .note)
        .onSubmit(submitMarker)
        .onChange(of: markerNote) { _, _ in markerError = nil }

      if let markerError {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
          .help(markerError)
      }
    }
    .textFieldStyle(.roundedBorder)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .overlay(alignment: .top) { Divider() }
    .disabled(!model.isLoaded || !model.canModifyMarkers)
    .onChange(of: focusedMarkerField) { oldValue, newValue in
      guard oldValue == .timecode, newValue != .timecode else { return }
      pendingTimecodeText = pendingMarkerTime.flatMap(Self.displayTimecode) ?? ""
    }
    .onKeyPress(.escape) {
      clearPendingMarkerTime()
      return .handled
    }
  }

  private var pendingTimecodeBinding: Binding<String> {
    Binding(
      get: { pendingTimecodeText },
      set: { newValue in
        pendingTimecodeText = newValue
        markerError = nil
        if pendingMarkerTime.flatMap(Self.displayTimecode) != newValue {
          pendingMarkerTime = nil
        }
      }
    )
  }

  private func submitMarker() {
    guard let player = model.player else { return }
    guard !markerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      setPendingMarkerTime(player.currentTime())
      return
    }

    guard
      model.createMarker(
        note: markerNote,
        at: pendingMarkerTime ?? player.currentTime()
      )
    else { return }
    markerNote = ""
    markerError = nil
    clearPendingMarkerTime()
  }

  private func commitPendingTimecode() {
    guard
      let time = Self.time(fromDisplayTimecode: pendingTimecodeText),
      model.durationSeconds <= 0 || Self.validSeconds(time) <= model.durationSeconds
    else {
      markerError = "Enter a valid recording time in HH:MM:SS.mmm format."
      NSSound.beep()
      return
    }
    setPendingMarkerTime(time)
  }

  private func setPendingMarkerTime(_ time: CMTime) {
    guard let timecode = Self.displayTimecode(time) else { return }
    pendingMarkerTime = time
    pendingTimecodeText = timecode
    markerError = nil
  }

  private func clearPendingMarkerTime() {
    pendingMarkerTime = nil
    pendingTimecodeText = ""
    markerError = nil
  }

  private static func displayTimecode(_ time: CMTime) -> String? {
    try? RecordingMarkerStore.displayTimecode(for: time)
  }

  private static func validSeconds(_ time: CMTime) -> Double {
    let seconds = time.seconds
    return seconds.isFinite && seconds >= 0 ? seconds : 0
  }

  private static func time(fromDisplayTimecode timecode: String) -> CMTime? {
    let components = timecode.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 3,
      let hours = Int64(components[0]),
      (0...999_999).contains(hours),
      let minutes = Int64(components[1]),
      (0..<60).contains(minutes)
    else { return nil }

    let secondComponents = components[2].split(separator: ".", omittingEmptySubsequences: false)
    guard secondComponents.count == 2,
      secondComponents[1].count == 3,
      let seconds = Int64(secondComponents[0]),
      let milliseconds = Int64(secondComponents[1]),
      (0..<60).contains(seconds),
      (0..<1_000).contains(milliseconds)
    else { return nil }

    let totalMilliseconds =
      hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds
    return CMTime(value: totalMilliseconds, timescale: 1_000)
  }

  private enum MarkerField: Hashable {
    case timecode
    case note
  }

  private enum PlayerFeature: Hashable {
    case markers
  }

  private var markerList: some View {
    VStack(alignment: .leading, spacing: 0) {
      Group {
        if model.markers.isEmpty {
          ContentUnavailableView(
            "No Markers",
            systemImage: "bookmark",
            description: Text("Saved markers appear here.")
          )
        } else {
          List(model.markers, id: \.fileURL, selection: $selectedMarkerURL) { marker in
            Button {
              selectedMarkerURL = marker.fileURL
              model.seek(to: marker.time)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                  Image(systemName: "bookmark.fill")
                  Text(marker.timecode)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                }
                .foregroundStyle(.secondary)
                Text(marker.note)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Go to \(marker.timecode)")
            .tag(marker.fileURL)
            .contextMenu {
              Button(role: .destructive) {
                deleteMarker(marker)
              } label: {
                Label("Delete Marker", systemImage: "trash")
              }
              .disabled(!model.canModifyMarkers)
            }
          }
          .listStyle(.inset)
          .onDeleteCommand(perform: deleteSelectedMarker)
        }
      }
    }
  }

  private func deleteSelectedMarker() {
    guard
      model.canModifyMarkers,
      let selectedMarkerURL,
      let marker = model.markers.first(where: { $0.fileURL == selectedMarkerURL })
    else { return }
    deleteMarker(marker)
  }

  private func deleteMarker(_ marker: RecordingMarker) {
    guard model.canModifyMarkers else { return }
    guard model.deleteMarker(marker) else { return }
    if selectedMarkerURL == marker.fileURL {
      selectedMarkerURL = nil
    }
    markerError = nil
  }

}

private struct LDTXPlaybackSeekRequest: Identifiable {
  let id = UUID()
  let time: CMTime
}

private struct LDTXPlaybackPane: NSViewControllerRepresentable {
  let player: AVPlayer?
  let durationSeconds: Double
  let seekRequest: LDTXPlaybackSeekRequest?

  func makeNSViewController(context: Context) -> LDTXPlaybackViewController {
    LDTXPlaybackViewController()
  }

  func updateNSViewController(
    _ viewController: LDTXPlaybackViewController,
    context: Context
  ) {
    viewController.update(
      player: player,
      durationSeconds: durationSeconds,
      seekRequest: seekRequest
    )
  }

  static func dismantleNSViewController(
    _ viewController: LDTXPlaybackViewController,
    coordinator: Void
  ) {
    viewController.stop()
  }
}

@MainActor
private final class LDTXPlaybackViewController: NSViewController {
  private let playerView = LDTXFocusablePlayerView()
  private let timecodeLabel = NSTextField(labelWithString: "00:00:00.000")
  private let playPauseButton = NSButton()
  private let scrubber = LDTXPlaybackScrubber()
  private var player: AVPlayer?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var durationSeconds = 0.0
  private var displayLink: CADisplayLink?
  private var resumesPlaybackAfterScrubbing = false
  private var isScrubbing = false
  private var requestedPreviewSeekTime: CMTime?
  private var isPreviewSeekInFlight = false
  private var seekGeneration = 0
  private var lastHandledSeekRequestID: UUID?

  override func loadView() {
    let rootView = NSView()

    configurePlayerView()
    let playbackBar = makePlaybackBar()

    for subview in [playerView, playbackBar] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      rootView.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      playerView.topAnchor.constraint(equalTo: rootView.topAnchor),
      playerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      playerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      playerView.bottomAnchor.constraint(equalTo: playbackBar.topAnchor),
      playbackBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      playbackBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      playbackBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])
    view = rootView
  }

  func update(
    player: AVPlayer?,
    durationSeconds: Double,
    seekRequest: LDTXPlaybackSeekRequest?
  ) {
    self.durationSeconds = max(durationSeconds, 0)
    scrubber.maxValue = max(self.durationSeconds, 0.001)
    scrubber.isEnabled = player != nil && self.durationSeconds > 0
    if self.player !== player {
      timeControlStatusObservation = nil
      stopDisplayLink()
      self.player = player
      playerView.player = player
      scrubber.doubleValue = Self.validSeconds(player?.currentTime() ?? .zero)
      updateTimecode(scrubber.doubleValue, includesMilliseconds: true)
      updatePlayPauseButton()
      if let player {
        startDisplayLink()
        observeTimeControlStatus(of: player)
      }
    }
    if let seekRequest, player != nil, seekRequest.id != lastHandledSeekRequestID {
      lastHandledSeekRequestID = seekRequest.id
      seek(to: seekRequest.time)
    }
  }

  func stop() {
    seekGeneration += 1
    requestedPreviewSeekTime = nil
    isPreviewSeekInFlight = false
    stopDisplayLink()
    timeControlStatusObservation = nil
    playerView.player = nil
    player = nil
    lastHandledSeekRequestID = nil
  }

  private func seek(to time: CMTime) {
    guard let player else { return }
    seekGeneration += 1
    let generation = seekGeneration
    requestedPreviewSeekTime = nil
    isPreviewSeekInFlight = false
    player.currentItem?.cancelPendingSeeks()
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak player] finished in
      Task { @MainActor in
        guard let self, let player, finished, generation == self.seekGeneration else { return }
        self.updatePlaybackPosition(player.currentTime())
        self.updatePlayPauseButton(player: player)
      }
    }
  }

  private func configurePlayerView() {
    playerView.controlsStyle = .none
    playerView.videoGravity = .resizeAspect
    playerView.allowsMagnification = true
    playerView.allowsPictureInPicturePlayback = false
    playerView.updatesNowPlayingInfoCenter = false
    playerView.allowsVideoFrameAnalysis = false
    let focusGestureRecognizer = NSClickGestureRecognizer(
      target: self,
      action: #selector(focusPlayerView)
    )
    focusGestureRecognizer.delaysPrimaryMouseButtonEvents = false
    playerView.addGestureRecognizer(focusGestureRecognizer)

    timecodeLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize,
      weight: .medium
    )
    timecodeLabel.textColor = .white
    timecodeLabel.drawsBackground = true
    timecodeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
    timecodeLabel.isBordered = false
    timecodeLabel.translatesAutoresizingMaskIntoConstraints = false
    playerView.contentOverlayView?.addSubview(timecodeLabel)
    if let overlayView = playerView.contentOverlayView {
      NSLayoutConstraint.activate([
        timecodeLabel.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: 12),
        timecodeLabel.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: -12),
      ])
    }
  }

  @objc private func focusPlayerView() {
    playerView.window?.makeFirstResponder(playerView)
  }

  private func makePlaybackBar() -> NSView {
    playPauseButton.image = NSImage(
      systemSymbolName: "play.fill",
      accessibilityDescription: "Play"
    )
    playPauseButton.bezelStyle = .accessoryBarAction
    playPauseButton.isBordered = false
    playPauseButton.target = self
    playPauseButton.action = #selector(togglePlayback)
    playPauseButton.isEnabled = false

    scrubber.minValue = 0
    scrubber.maxValue = 0.001
    scrubber.isContinuous = true
    scrubber.isEnabled = false
    scrubber.target = self
    scrubber.action = #selector(scrubberChanged)
    scrubber.beginTracking = { [weak self] in self?.beginScrubbing() }
    scrubber.endTracking = { [weak self] in self?.endScrubbing() }

    let stack = NSStackView(views: [playPauseButton, scrubber])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    let bar = NSVisualEffectView()
    bar.material = .headerView
    bar.blendingMode = .withinWindow
    stack.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: bar.topAnchor),
      stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
    ])
    return bar
  }

  @objc private func togglePlayback() {
    guard let player else { return }
    if player.timeControlStatus == .playing {
      player.pause()
      updatePlaybackPosition(player.currentTime())
      displayLink?.isPaused = true
    } else {
      if durationSeconds > 0, Self.validSeconds(player.currentTime()) >= durationSeconds {
        player.seek(to: .zero)
      }
      player.play()
      displayLink?.isPaused = false
    }
    updatePlayPauseButton()
  }

  @objc private func scrubberChanged() {
    guard let player else { return }
    let target = CMTime(seconds: scrubber.doubleValue, preferredTimescale: 600)
    updateTimecode(scrubber.doubleValue, includesMilliseconds: true)
    if isScrubbing {
      requestedPreviewSeekTime = target
    } else {
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
  }

  private func beginScrubbing() {
    guard let player else { return }
    seekGeneration += 1
    isScrubbing = true
    requestedPreviewSeekTime = nil
    isPreviewSeekInFlight = false
    resumesPlaybackAfterScrubbing = player.timeControlStatus == .playing
    player.pause()
    configureDisplayLinkForScrubbing()
    displayLink?.isPaused = false
    updatePlayPauseButton()
  }

  private func endScrubbing() {
    guard let player else { return }
    isScrubbing = false
    requestedPreviewSeekTime = nil
    isPreviewSeekInFlight = false
    seekGeneration += 1
    let generation = seekGeneration
    displayLink?.isPaused = true
    let shouldResume = resumesPlaybackAfterScrubbing
    resumesPlaybackAfterScrubbing = false
    let target = CMTime(seconds: scrubber.doubleValue, preferredTimescale: 600)
    player.currentItem?.cancelPendingSeeks()
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak player] finished in
      Task { @MainActor in
        guard let self, let player, generation == self.seekGeneration else { return }
        self.updatePlaybackPosition(target)
        if finished, shouldResume {
          player.play()
          self.configureDisplayLinkForPlayback()
          self.displayLink?.isPaused = false
        }
        self.updatePlayPauseButton()
      }
    }
  }

  private func startDisplayLink() {
    let displayLink = playerView.displayLink(
      target: self,
      selector: #selector(displayLinkDidFire(_:))
    )
    configureDisplayLinkForPlayback(displayLink)
    displayLink.add(to: .main, forMode: .common)
    self.displayLink = displayLink
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private func observeTimeControlStatus(of player: AVPlayer) {
    timeControlStatusObservation = player.observe(
      \.timeControlStatus,
      options: [.initial, .new]
    ) { [weak self, weak player] _, _ in
      Task { @MainActor in
        guard let self, let player, self.player === player else { return }
        self.updatePlayPauseButton(player: player)
        if self.isScrubbing {
          self.configureDisplayLinkForScrubbing()
          self.displayLink?.isPaused = false
          return
        }
        if player.timeControlStatus == .paused {
          self.displayLink?.isPaused = true
          self.updatePlaybackPosition(player.currentTime())
        } else {
          self.configureDisplayLinkForPlayback()
          self.displayLink?.isPaused = false
        }
      }
    }
  }

  @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
    guard let player else { return }
    if isScrubbing {
      performLatestPreviewSeekIfPossible(on: player)
      return
    }
    if !scrubber.isActivelyTracking {
      updatePlaybackPosition(player.currentTime())
    }
    updatePlayPauseButton(player: player)
    if player.timeControlStatus == .paused {
      displayLink.isPaused = true
      updatePlaybackPosition(player.currentTime())
    }
  }

  private func performLatestPreviewSeekIfPossible(on player: AVPlayer) {
    guard !isPreviewSeekInFlight, let target = requestedPreviewSeekTime else { return }
    requestedPreviewSeekTime = nil
    isPreviewSeekInFlight = true
    let generation = seekGeneration
    let tolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
    player.seek(
      to: target,
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, generation == self.seekGeneration else { return }
        self.isPreviewSeekInFlight = false
      }
    }
  }

  private func configureDisplayLinkForPlayback(_ displayLink: CADisplayLink? = nil) {
    (displayLink ?? self.displayLink)?.preferredFrameRateRange = CAFrameRateRange(
      minimum: 30,
      maximum: 60,
      preferred: 60
    )
  }

  private func configureDisplayLinkForScrubbing() {
    displayLink?.preferredFrameRateRange = CAFrameRateRange(
      minimum: 30,
      maximum: 30,
      preferred: 30
    )
  }

  private func updateTimecode(_ seconds: Double, includesMilliseconds: Bool) {
    let time = CMTime(seconds: seconds, preferredTimescale: 1_000)
    let timecode =
      (try? RecordingMarkerStore.displayTimecode(for: time)) ?? "00:00:00.000"
    timecodeLabel.stringValue =
      includesMilliseconds
      ? timecode
      : String(timecode.dropLast(4))
  }

  private func updatePlaybackPosition(_ time: CMTime) {
    let seconds = Self.validSeconds(time)
    scrubber.doubleValue = min(seconds, durationSeconds)
    updateTimecode(
      seconds,
      includesMilliseconds: player?.timeControlStatus != .playing
    )
  }

  private func updatePlayPauseButton(player: AVPlayer? = nil) {
    let player = player ?? self.player
    let isPlaying = player?.timeControlStatus == .playing
    let symbolName = isPlaying ? "pause.fill" : "play.fill"
    let description = isPlaying ? "Pause" : "Play"
    playPauseButton.image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: description
    )
    playPauseButton.toolTip = description
    playPauseButton.isEnabled = player != nil
  }

  private static func validSeconds(_ time: CMTime) -> Double {
    let seconds = time.seconds
    return seconds.isFinite && seconds >= 0 ? seconds : 0
  }

}

@MainActor
private final class LDTXFocusablePlayerView: AVPlayerView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class LDTXPlaybackScrubber: NSSlider {
  var beginTracking: (() -> Void)?
  var endTracking: (() -> Void)?
  private(set) var isActivelyTracking = false

  override func mouseDown(with event: NSEvent) {
    isActivelyTracking = true
    beginTracking?()
    moveImmediatelyToClickIfNeeded(event)
    super.mouseDown(with: event)
    endTracking?()
    isActivelyTracking = false
  }

  private func moveImmediatelyToClickIfNeeded(_ event: NSEvent) {
    guard let sliderCell = cell as? NSSliderCell else { return }
    let location = convert(event.locationInWindow, from: nil)
    let knobRect = sliderCell.knobRect(flipped: isFlipped)
    guard !knobRect.contains(location) else { return }

    let barRect = sliderCell.barRect(flipped: isFlipped)
    let lowerBound = barRect.minX + knobRect.width / 2
    let upperBound = barRect.maxX - knobRect.width / 2
    guard upperBound > lowerBound else { return }

    let fraction = Swift.min(Swift.max((location.x - lowerBound) / (upperBound - lowerBound), 0), 1)
    doubleValue = minValue + Double(fraction) * (maxValue - minValue)
    sendAction(action, to: target)
  }
}

@MainActor
@Observable
private final class LDTXRecordPlayerModel {
  var player: AVPlayer?
  var markers: [RecordingMarker] = []
  var playbackSeekRequest: LDTXPlaybackSeekRequest?
  var alert: LDTXRecordPlayerAlert?
  var isLoading = true
  var shouldClose = false
  var durationSeconds = 0.0
  var availableCanvases: [RecordingCanvas] = []
  var selectedCanvas: RecordingCanvas = .landscape

  private let recordingURL: URL
  private let securityScopedURL: URL
  private let scenarioFixture: RecordingPreviewScenarioFixture?
  private let assetLoader: LDTXRecordPlayerAssetLoader
  private let isAccessingSecurityScopedResource: Bool
  private var markerStore: RecordingMarkerStore?
  private var loadTask: Task<Void, Never>?

  init(
    recordingURL: URL,
    scenarioFixture: RecordingPreviewScenarioFixture?,
    assetLoader: @escaping LDTXRecordPlayerAssetLoader
  ) {
    securityScopedURL = recordingURL
    self.recordingURL = recordingURL.standardizedFileURL
    self.scenarioFixture = scenarioFixture
    self.assetLoader = assetLoader
    isAccessingSecurityScopedResource = recordingURL.startAccessingSecurityScopedResource()
  }

  deinit {
    if isAccessingSecurityScopedResource {
      securityScopedURL.stopAccessingSecurityScopedResource()
    }
  }

  var isLoaded: Bool {
    player != nil && markerStore != nil
  }

  var canModifyMarkers: Bool {
    !FileManager.default.fileExists(
      atPath: recordingURL.appendingPathComponent(".shield.json").path
    )
  }

  func start() {
    guard loadTask == nil else { return }
    loadTask = Task { await load() }
  }

  func stop() {
    loadTask?.cancel()
    player?.pause()
    player = nil
  }

  func selectCanvas(_ canvas: RecordingCanvas) {
    guard availableCanvases.contains(canvas) else { return }
    let resumeTime = player?.currentTime() ?? .zero
    let resumesPlayback = player?.timeControlStatus == .playing
    player?.pause()
    player = nil
    isLoading = true
    loadTask?.cancel()
    loadTask = Task { await load(resumeAt: resumeTime, startsPlaying: resumesPlayback) }
  }

  func seek(to time: CMTime) {
    playbackSeekRequest = LDTXPlaybackSeekRequest(time: time)
  }

  func createMarker(note: String, at time: CMTime) -> Bool {
    guard let markerStore else {
      closeAfterInternalError("Marker creation was requested before the recording was loaded.")
      return false
    }

    do {
      _ = try markerStore.createMarker(at: time, note: note)
      markers = try markerStore.markers()
      return true
    } catch {
      presentMarkerFileError(title: "Marker Could Not Be Saved", error: error)
      return false
    }
  }

  func deleteMarker(_ marker: RecordingMarker) -> Bool {
    guard let markerStore else {
      closeAfterInternalError("Marker deletion was requested before the recording was loaded.")
      return false
    }

    do {
      try markerStore.deleteMarker(marker)
      markers = try markerStore.markers()
      return true
    } catch {
      presentMarkerFileError(title: "Marker Could Not Be Deleted", error: error)
      return false
    }
  }

  private func presentMarkerFileError(title: String, error: any Error) {
    recordingPreviewLogger.error(
      "Marker file operation failed: \(error.localizedDescription, privacy: .public)"
    )
    alert = LDTXRecordPlayerAlert(
      title: title,
      message: error.localizedDescription
    )
  }

  private func load(resumeAt: CMTime = .zero, startsPlaying: Bool = true) async {
    recordingPreviewLogger.info(
      "Loading recording preview for \(self.recordingURL.lastPathComponent, privacy: .public)"
    )
    if await loadScenarioFixtureIfNeeded() { return }

    do {
      let markerStore = RecordingMarkerStore(recordingDirectoryURL: recordingURL)
      let package = try RecordingPackage(contentsOf: recordingURL)
      availableCanvases = package.availableCanvases.filter { canvas in
        guard let media = package.media(for: canvas) else { return false }
        return FileManager.default.fileExists(atPath: media.url.path)
      }
      if !availableCanvases.isEmpty, !availableCanvases.contains(selectedCanvas) {
        selectedCanvas = availableCanvases[0]
      }
      let selected = package.formatVersion >= 3 ? selectedCanvas : nil
      let asset = try await assetLoader(recordingURL, selected)
      guard !Task.isCancelled else { return }

      self.markerStore = markerStore
      do {
        markers = try markerStore.markers()
      } catch {
        markers = []
        recordingPreviewLogger.error(
          "Loading optional markers failed: \(error.localizedDescription, privacy: .public)"
        )
      }
      let duration = try await asset.load(.duration)
      durationSeconds = Self.validSeconds(duration)
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      self.player = player
      isLoading = false
      if resumeAt > .zero {
        await player.seek(to: resumeAt)
      }
      if startsPlaying { player.play() }
    } catch {
      guard !Task.isCancelled else { return }
      isLoading = false
      recordingPreviewLogger.error(
        "Recording preview load failed: \(error.localizedDescription, privacy: .public)"
      )
      alert = LDTXRecordPlayerAlert(
        title: "Recording Could Not Be Opened",
        message: error.localizedDescription,
        closeAfterDismissal: true
      )
    }
  }

  private func closeAfterInternalError(_ message: String) {
    recordingPreviewLogger.error("\(message, privacy: .public)")
    shouldClose = true
  }

  private static func validSeconds(_ time: CMTime) -> Double {
    let seconds = time.seconds
    return seconds.isFinite && seconds >= 0 ? seconds : 0
  }

  private func loadScenarioFixtureIfNeeded() async -> Bool {
    guard let scenarioFixture else { return false }
    recordingPreviewLogger.notice(
      "Activating recording preview fixture \(scenarioFixture.rawValue, privacy: .public)"
    )

    switch scenarioFixture {
    case .initialLoadFailure:
      isLoading = false
      alert = LDTXRecordPlayerAlert(
        title: "Recording Could Not Be Opened",
        message: "The scenario fixture could not open the recording.",
        closeAfterDismissal: true
      )
    case .internalStateFailure:
      await Task.yield()
      closeAfterInternalError("The internal-state-failure scenario fixture was activated.")
    }
    return true
  }
}

private struct LDTXRecordPlayerAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  var closeAfterDismissal = false
}
