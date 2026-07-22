// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AVKit
import AppKit
import LDTXRecording
import QuickLookUI

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
  private static weak var activeController: PreviewViewController?
  private static let compositionLoadMap = PreviewCompositionLoadMap(maximumCount: 8)

  private var playerView: AVPlayerView!
  private let messageLabel = NSTextField(labelWithString: "")
  private let controllerID = String(UUID().uuidString.prefix(8))
  private let player = AVPlayer()
  private var loadRequestID: PreviewCompositionLoadMap.RequestID?
  private var playbackProbeTask: Task<Void, Never>?
  private var preparationCompletionTask: Task<Void, Never>?
  private var playerItemTimeoutTask: Task<Void, Never>?
  private var playerItemStatusObservation: NSKeyValueObservation?
  private var previewURL: URL?
  private var currentCompletion: PreviewCompletion?
  private var requestGeneration: UInt64 = 0
  private var requiresExplicitRetry = false
  private var isPreviewVisible = false

  override func loadView() {
    let rootView = NSView()
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor(
      calibratedRed: 0x77 / 255.0,
      green: 0x77 / 255.0,
      blue: 0x77 / 255.0,
      alpha: 1
    ).cgColor

    let playerView = AVPlayerView()
    playerView.controlsStyle = .inline
    playerView.videoGravity = .resizeAspect
    playerView.translatesAutoresizingMaskIntoConstraints = false
    playerView.player = player
    self.playerView = playerView

    messageLabel.alignment = .center
    messageLabel.lineBreakMode = .byWordWrapping
    messageLabel.maximumNumberOfLines = 0
    messageLabel.textColor = .white
    messageLabel.isHidden = true
    messageLabel.translatesAutoresizingMaskIntoConstraints = false

    rootView.addSubview(playerView)
    rootView.addSubview(messageLabel)
    NSLayoutConstraint.activate([
      playerView.topAnchor.constraint(equalTo: rootView.topAnchor),
      playerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      playerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      playerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      messageLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      messageLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
      messageLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: rootView.leadingAnchor, constant: 32),
      messageLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: rootView.trailingAnchor, constant: -32),
    ])

    preferredContentSize = NSSize(width: 960, height: 540)
    view = rootView
  }

  nonisolated func preparePreviewOfFile(
    at url: URL,
    completionHandler handler: @escaping (Error?) -> Void
  ) {
    let completion = PreviewCompletion(handler)
    Task { @MainActor [weak self] in
      guard let self else {
        completion.call(CancellationError())
        return
      }
      self.requiresExplicitRetry = false
      self.preparePreview(of: url, completion: completion)
    }
  }

  private func preparePreview(of url: URL, completion: PreviewCompletion? = nil) {
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) preparing \(url.lastPathComponent, privacy: .public); previous generation \(self.requestGeneration)."
    )
    if let activeController = Self.activeController, activeController !== self {
      activeController.pausePlayback()
      activeController.messageLabel.isHidden = true
    }
    Self.activeController = self
    stopLoading()
    previewURL = url
    messageLabel.isHidden = true
    playerView.isHidden = false
    currentCompletion = completion
    requestGeneration &+= 1
    let generation = requestGeneration
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) requesting generation \(generation) for \(url.lastPathComponent, privacy: .public)."
    )

    loadRequestID = Self.compositionLoadMap.requestComposition(for: url) {
      [weak self] result in
      guard let self, generation == requestGeneration else {
        quickLookPreviewLogger.notice(
          "Ignoring stale UI result for generation \(generation), current generation \(self?.requestGeneration ?? 0)."
        )
        completion?.call(nil)
        return
      }
      quickLookPreviewLogger.notice(
        "Controller \(self.controllerID, privacy: .public) received result for generation \(generation)."
      )
      loadRequestID = nil
      switch result {
      case .success(let composition):
        requiresExplicitRetry = false
        let item = AVPlayerItem(asset: composition)
        player.replaceCurrentItem(with: item)
        if isPreviewVisible {
          player.play()
          quickLookPreviewLogger.notice(
            "Controller \(self.controllerID, privacy: .public) started playback for \(url.lastPathComponent, privacy: .public), generation \(generation)."
          )
        } else {
          quickLookPreviewLogger.notice(
            "Controller \(self.controllerID, privacy: .public) prepared \(url.lastPathComponent, privacy: .public) while hidden, generation \(generation); playback remains paused."
          )
        }
        startPlaybackProbe(generation: generation, url: url)
        observePlayerItemStatus(
          item,
          generation: generation,
          url: url,
          completion: completion
        )
      case .failure(let error):
        requiresExplicitRetry = true
        currentCompletion = nil
        quickLookPreviewLogger.error(
          "Controller \(self.controllerID, privacy: .public) failed \(url.lastPathComponent, privacy: .public), generation \(generation): \(error.localizedDescription, privacy: .public)"
        )
        show(error: error)
        completion?.call(nil)
      }
    }
  }

  private func show(error: Error) {
    player.pause()
    player.replaceCurrentItem(with: nil)
    playerView.isHidden = true
    messageLabel.stringValue = error.localizedDescription
    messageLabel.isHidden = false
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    isPreviewVisible = false
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) view will disappear at generation \(self.requestGeneration)."
    )
    pausePlayback()
    if Self.activeController === self {
      Self.activeController = nil
    }
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    isPreviewVisible = false
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) view did disappear at generation \(self.requestGeneration)."
    )
    pausePlayback()
    if Self.activeController === self {
      Self.activeController = nil
    }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    isPreviewVisible = true
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) view will appear; generation \(self.requestGeneration), has item \(self.player.currentItem != nil), has request \(self.loadRequestID != nil), explicit retry required \(self.requiresExplicitRetry)."
    )
    if !requiresExplicitRetry, player.currentItem == nil, loadRequestID == nil, let previewURL {
      preparePreview(of: previewURL)
    } else {
      resumePreview()
    }
  }

  private func resumePreview() {
    guard isPreviewVisible, player.currentItem != nil else { return }
    if let activeController = Self.activeController, activeController !== self {
      activeController.pausePlayback()
    }
    Self.activeController = self
    player.play()
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) resumed playback at generation \(self.requestGeneration)."
    )
  }

  private func stopLoading() {
    let wasActive = loadRequestID != nil || player.currentItem != nil || currentCompletion != nil
    let stoppedRequestID = loadRequestID
    let stoppedURL = previewURL?.lastPathComponent ?? "none"
    playbackProbeTask?.cancel()
    playbackProbeTask = nil
    preparationCompletionTask?.cancel()
    preparationCompletionTask = nil
    playerItemTimeoutTask?.cancel()
    playerItemTimeoutTask = nil
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
    if let loadRequestID {
      Self.compositionLoadMap.cancelRequest(loadRequestID)
    }
    loadRequestID = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    requestGeneration &+= 1
    currentCompletion?.call(nil)
    currentCompletion = nil
    if wasActive {
      quickLookPreviewLogger.notice(
        "Controller \(self.controllerID, privacy: .public) stopped \(stoppedURL, privacy: .public); request \(stoppedRequestID?.uuidString ?? "none", privacy: .public), new generation \(self.requestGeneration)."
      )
    }
  }

  private func pausePlayback() {
    guard player.currentItem != nil else { return }
    player.pause()
    quickLookPreviewLogger.notice(
      "Controller \(self.controllerID, privacy: .public) paused playback at generation \(self.requestGeneration), time \(self.player.currentTime().seconds)."
    )
  }

  private func observePlayerItemStatus(
    _ item: AVPlayerItem,
    generation: UInt64,
    url: URL,
    completion: PreviewCompletion?
  ) {
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.handlePlayerItemStatus(
          generation: generation,
          url: url,
          completion: completion
        )
      }
    }

    preparationCompletionTask?.cancel()
    preparationCompletionTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      guard let self, generation == requestGeneration else { return }
      preparationCompletionTask = nil
      currentCompletion = nil
      quickLookPreviewLogger.notice(
        "Controller \(self.controllerID, privacy: .public) completed Quick Look preparation for \(url.lastPathComponent, privacy: .public), generation \(generation), after readiness timeout; continuing status observation."
      )
      completion?.call(nil)
    }

    playerItemTimeoutTask?.cancel()
    playerItemTimeoutTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        return
      }
      guard
        let self,
        generation == requestGeneration,
        player.currentItem?.status == .unknown
      else { return }
      playerItemTimeoutTask = nil
      preparationCompletionTask?.cancel()
      preparationCompletionTask = nil
      currentCompletion = nil
      requiresExplicitRetry = true
      playerItemStatusObservation?.invalidate()
      playerItemStatusObservation = nil
      quickLookPreviewLogger.error(
        "Controller \(self.controllerID, privacy: .public) timed out waiting for player item status for \(url.lastPathComponent, privacy: .public), generation \(generation)."
      )
      show(error: PreviewPlaybackError.playerItemTimedOut)
      completion?.call(nil)
    }
  }

  private func handlePlayerItemStatus(
    generation: UInt64,
    url: URL,
    completion: PreviewCompletion?
  ) {
    guard generation == requestGeneration, let item = player.currentItem else { return }
    switch item.status {
    case .readyToPlay:
      playerItemTimeoutTask?.cancel()
      playerItemTimeoutTask = nil
      preparationCompletionTask?.cancel()
      preparationCompletionTask = nil
      currentCompletion = nil
      quickLookPreviewLogger.notice(
        "Controller \(self.controllerID, privacy: .public) completed Quick Look preparation for \(url.lastPathComponent, privacy: .public), generation \(generation), after player became ready."
      )
      completion?.call(nil)
    case .failed:
      playerItemTimeoutTask?.cancel()
      playerItemTimeoutTask = nil
      preparationCompletionTask?.cancel()
      preparationCompletionTask = nil
      currentCompletion = nil
      requiresExplicitRetry = true
      let error = item.error ?? PreviewPlaybackError.playerItemFailed
      playerItemStatusObservation?.invalidate()
      playerItemStatusObservation = nil
      quickLookPreviewLogger.error(
        "Controller \(self.controllerID, privacy: .public) player item failed for \(url.lastPathComponent, privacy: .public), generation \(generation): \(error.localizedDescription, privacy: .public)"
      )
      show(error: error)
      completion?.call(nil)
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  private func startPlaybackProbe(generation: UInt64, url: URL) {
    playbackProbeTask?.cancel()
    playbackProbeTask = Task { @MainActor [weak self] in
      for (delay, elapsed) in [(100, 100), (400, 500), (1_000, 1_500)] {
        try? await Task.sleep(for: .milliseconds(delay))
        guard !Task.isCancelled, let self else { return }
        quickLookPreviewLogger.notice(
          "Controller \(self.controllerID, privacy: .public) probe \(elapsed)ms for \(url.lastPathComponent, privacy: .public), generation \(generation): status \(self.player.timeControlStatus.rawValue), rate \(self.player.rate), time \(self.player.currentTime().seconds)."
        )
      }
    }
  }
}

private enum PreviewPlaybackError: Error, LocalizedError {
  case playerItemFailed
  case playerItemTimedOut

  var errorDescription: String? {
    switch self {
    case .playerItemFailed:
      "The recording could not be prepared for playback. Try this file again."
    case .playerItemTimedOut:
      "Preparing the recording for playback took too long. Try this file again."
    }
  }
}

private final class PreviewCompletion: @unchecked Sendable {
  private let handler: (Error?) -> Void
  private let lock = NSLock()
  private var isCompleted = false

  init(_ handler: @escaping (Error?) -> Void) {
    self.handler = handler
  }

  func call(_ error: Error?) {
    lock.lock()
    guard !isCompleted else {
      lock.unlock()
      return
    }
    isCompleted = true
    lock.unlock()
    handler(error)
  }
}
