// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AppKit
import LDTXRecordPlayerUI
import LDTXRecording
import SwiftUI
import UniformTypeIdentifiers

@main
struct LDTXPlayerApplication: App {
  @NSApplicationDelegateAdaptor(LDTXPlayerApplicationDelegate.self) private var appDelegate

  var body: some Scene {
    Window("LDTX Player", id: "launcher") {
      LDTXPlayerLauncher()
    }
    .defaultSize(width: 420, height: 260)
    .windowResizability(.contentSize)
    .commands {
      LDTXPlayerFileCommands()
      InspectorCommands()
    }

    WindowGroup("Recording Preview", id: "recording-preview", for: URL.self) { recordingURL in
      if let recordingURL = recordingURL.wrappedValue {
        LDTXPlayerRecordingScene(recordingURL: recordingURL)
      }
    }
    .restorationBehavior(.disabled)
    .handlesExternalEvents(matching: [])
    .defaultSize(width: 960, height: 600)
    .windowResizability(.contentMinSize)
    .commands {
      LDTXPlayerFileCommands()
      InspectorCommands()
    }
  }
}

private struct LDTXPlayerRecordingScene: View {
  @Environment(\.dismissWindow) private var dismissWindow

  let recordingURL: URL

  var body: some View {
    LDTXRecordPlayerView(
      recordingURL: recordingURL,
      assetLoader: LDTXPlayerMainMixAssetLoader.load,
      closePreview: {
        dismissWindow(id: "recording-preview", value: recordingURL)
      }
    )
    .navigationTitle(recordingURL.deletingPathExtension().lastPathComponent)
  }
}

@MainActor
private enum LDTXPlayerMainMixAssetLoader {
  private static let mainMediaPath = "main.fragmented.mp4"

  static func load(recordingURL: URL) async throws -> AVAsset {
    let asset = AVURLAsset(url: recordingURL.appendingPathComponent(mainMediaPath))
    let timeline = try RecordingDASHTimeline(
      contentsOf: recordingURL.appendingPathComponent("manifest.mpd")
    )
    let composition = AVMutableComposition()
    let presentationStart = timeline.presentationStart(for: mainMediaPath)

    try await insertFirstTrack(
      from: asset,
      mediaType: .video,
      at: presentationStart,
      into: composition
    )
    try await insertFirstTrack(
      from: asset,
      mediaType: .audio,
      at: nil,
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
}

private struct LDTXPlayerLauncher: View {
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "play.rectangle.on.rectangle")
        .font(.system(size: 44))
        .foregroundStyle(.tint)
      Text("LDTX Player")
        .font(.largeTitle.bold())
      Button("Open Recording…") {
        chooseRecording()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(36)
    .task {
      LDTXPlayerOpenCoordinator.shared.install { url in
        openWindow(id: "recording-preview", value: url)
        dismissWindow(id: "launcher")
      }
    }
  }

  private func chooseRecording() {
    guard let url = LDTXPlayerOpenPanel.chooseRecording() else { return }
    LDTXPlayerOpenCoordinator.shared.open(url)
  }
}

private struct LDTXPlayerFileCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Open Recording…") {
        guard let url = LDTXPlayerOpenPanel.chooseRecording() else { return }
        LDTXPlayerOpenCoordinator.shared.open(url)
      }
      .keyboardShortcut("o", modifiers: .command)
    }
  }
}

@MainActor
private enum LDTXPlayerOpenPanel {
  static func chooseRecording() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.ldtxRecording]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Open an LDTX recording."
    panel.prompt = "Open"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}

@MainActor
private final class LDTXPlayerOpenCoordinator {
  static let shared = LDTXPlayerOpenCoordinator()

  private var handler: ((URL) -> Void)?
  private var pendingURLs: [URL] = []

  func install(handler: @escaping (URL) -> Void) {
    self.handler = handler
    let pendingURLs = self.pendingURLs
    self.pendingURLs.removeAll()
    for url in pendingURLs {
      handler(url)
    }
  }

  func open(_ url: URL) {
    guard let handler else {
      pendingURLs.append(url)
      return
    }
    handler(url)
  }
}

@MainActor
private final class LDTXPlayerApplicationDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.pathExtension.lowercased() == "ldtxrecord" {
      LDTXPlayerOpenCoordinator.shared.open(url)
    }
  }
}

extension UTType {
  fileprivate static let ldtxRecording = UTType(importedAs: "tokyo.kaito.ldtx.recording")
}
