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
@MainActor
private enum LDTXPlayerApplication {
  static func main() {
    let app = NSApplication.shared
    let delegate = LDTXPlayerApplicationDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor
private final class LDTXPlayerApplicationDelegate: NSObject, NSApplicationDelegate {
  private var windows: [URL: RecordingWindowController] = [:]
  private var launcher: NSWindowController?
  private var closeObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenus()
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        self.windows = self.windows.filter { $0.value.window !== window }
      }
    }
    if windows.isEmpty { showLauncher() }
    NSApp.activate(ignoringOtherApps: true)
  }
  func application(_ app: NSApplication, open urls: [URL]) {
    for url in urls where url.isFileURL && url.pathExtension.lowercased() == "ldtxrecord" {
      openRecording(url)
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showLauncher() }
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    for controller in windows.values { controller.close() }
  }
  private func openRecording(_ url: URL) {
    let url = url.standardizedFileURL
    if let controller = windows[url] {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = RecordingWindowController(
      recordingURL: url, assetLoader: LDTXPlayerMainMixAssetLoader.load)
    windows[url] = controller
    controller.showWindow(nil)
    launcher?.close()
  }
  private func showLauncher() {
    if launcher == nil {
      let window = NSWindow(
        contentViewController: NSHostingController(
          rootView: LDTXPlayerLauncher(open: { [weak self] in self?.openFile(nil) })))
      window.title = "LDTX Player"
      window.setContentSize(NSSize(width: 420, height: 260))
      window.center()
      window.styleMask.remove(.resizable)
      window.isReleasedWhenClosed = false
      launcher = NSWindowController(window: window)
    }
    launcher?.showWindow(nil)
    launcher?.window?.makeKeyAndOrderFront(nil)
  }
  @objc private func openFile(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.recording")]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openRecording(url)
  }
  @objc private func toggleInspector(_ sender: Any?) {
    (NSApp.keyWindow?.windowController as? RecordingWindowController)?.toggleInspector(sender)
  }
  private func installMenus() {
    let main = NSMenu()
    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      item.submenu = menu
      main.addItem(item)
      return menu
    }
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
      target: AnyObject? = nil
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = target
      menu.addItem(item)
    }
    let app = menu("LDTX Player")
    add(app, "About LDTX Player", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    add(app, "Hide LDTX Player", #selector(NSApplication.hide(_:)), "h")
    add(app, "Quit LDTX Player", #selector(NSApplication.terminate(_:)), "q")
    let file = menu("File")
    add(file, "Open Recording…", #selector(openFile), "o", target: self)
    add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
    let edit = menu("Edit")
    for (title, selector, key) in [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] { add(edit, title, NSSelectorFromString(selector), key) }
    let view = menu("View")
    add(view, "Toggle Inspector", #selector(toggleInspector), target: self)
    let window = menu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    NSApp.windowsMenu = window
    NSApp.mainMenu = main
  }
}

private struct LDTXPlayerLauncher: View {
  let open: () -> Void
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44)).foregroundStyle(
        .tint)
      Text("LDTX Player").font(.largeTitle.bold())
      Button("Open Recording…", action: open).keyboardShortcut(.defaultAction)
    }.padding(36)
  }
}

@MainActor
private enum LDTXPlayerMainMixAssetLoader {
  static func load(recordingURL: URL, canvas: RecordingCanvas?) async throws -> AVAsset {
    let package = try RecordingPackage(contentsOf: recordingURL)
    let media = canvas.flatMap(package.media(for:))
    let mediaPath = media?.path ?? package.mainMediaPath
    let asset = AVURLAsset(url: media?.url ?? package.mainMediaURL)
    let timeline = try RecordingDASHTimeline(
      contentsOf: recordingURL.appendingPathComponent("manifest.mpd")
    )
    let composition = AVMutableComposition()
    let presentationStart = timeline.presentationStart(for: mediaPath)

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
