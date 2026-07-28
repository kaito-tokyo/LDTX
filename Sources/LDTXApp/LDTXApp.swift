// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXRecording
import LDTXWorkspace
import LDTXYouTubeAuth
import SwiftUI
import UniformTypeIdentifiers

struct LDTXApp: App {
  @NSApplicationDelegateAdaptor(LDTXApplicationDelegate.self) private var appDelegate
  @StateObject private var oauthClientState: OAuthClientState
  @StateObject private var authState: YouTubeAuthState
  private let youtubeClientService: YouTubeClientService

  init() {
    let youtubeClientService = AppFeatureComposition.makeYouTubeClientService()
    self.youtubeClientService = youtubeClientService
    _oauthClientState = StateObject(
      wrappedValue: OAuthClientState(
        youtubeClientService: youtubeClientService,
        restoresPersistedOAuthClient: true
      )
    )
    _authState = StateObject(
      wrappedValue: YouTubeAuthState(youtubeClientService: youtubeClientService)
    )
  }

  var body: some Scene {
    Window("LDTX", id: "launcher") {
      LauncherView()
        .modifier(ApplicationRouterInstaller(applicationRouter: appDelegate.applicationRouter))
    }
    .defaultSize(width: 420, height: 260)
    .windowResizability(.contentSize)
    .commands {
      ApplicationFileCommands()
    }
    WindowGroup("Workspace", id: "workspace-editor", for: WorkspaceEditorWindowRequest.self) { request in
      if let request = request.wrappedValue {
        WorkspaceEditorWindow(
          request: request,
          applicationRouter: appDelegate.applicationRouter,
          oauthClientState: oauthClientState,
          authState: authState,
          youtubeClientService: youtubeClientService,
          lowFrequencyUpdateRegistry: appDelegate.lowFrequencyUpdateRegistry
        )
        .modifier(ApplicationRouterInstaller(applicationRouter: appDelegate.applicationRouter))
      }
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      ApplicationFileCommands()
    }
    WindowGroup("Recording Preview", id: "recording-preview", for: URL.self) { recordingURL in
      if let recordingURL = recordingURL.wrappedValue {
        RecordingPreviewScene(recordingURL: recordingURL)
        .modifier(ApplicationRouterInstaller(applicationRouter: appDelegate.applicationRouter))
      }
    }
    .handlesExternalEvents(matching: [])
    .defaultSize(width: 960, height: 600)
    .windowResizability(.contentMinSize)
    .commands {
      ApplicationFileCommands()
    }
    Settings {
      SettingsView {
        YouTubeAccountSettingsView(
          oauthStatus: oauthClientState.status,
          authorizationStatus: authState.status,
          isImportingOAuthClient: Binding(
            get: { oauthClientState.isImportingOAuthClient },
            set: { oauthClientState.isImportingOAuthClient = $0 }
          ),
          canAuthorize: oauthClientState.configuration != nil && !authState.isAuthorizing,
          restoreAuthorization: {
            authState.restore(for: oauthClientState.configuration)
          },
          authorizeYouTube: {
            authState.authorize(configuration: oauthClientState.configuration)
          },
          loadOAuthClient: { url in
            oauthClientState.load(from: url) != nil
          }
        )
      }
      .modifier(ApplicationRouterInstaller(applicationRouter: appDelegate.applicationRouter))
    }
  }
}

struct WorkspaceEditorWindowRequest: Codable, Hashable {
  enum Source: Codable, Hashable {
    case new
    case file(URL)
  }

  let windowSequence: Int
  let unsavedSequence: Int?
  let source: Source

  @MainActor
  static func new() -> Self {
    Self(
      windowSequence: WorkspaceSceneSequence.nextWindow(),
      unsavedSequence: WorkspaceSceneSequence.nextUnsaved(),
      source: .new
    )
  }

  @MainActor
  static func file(_ url: URL) -> Self {
    Self(
      windowSequence: WorkspaceSceneSequence.nextWindow(),
      unsavedSequence: nil,
      source: .file(url.standardizedFileURL)
    )
  }
}

typealias WorkspaceSceneRequest = WorkspaceEditorWindowRequest

@MainActor
enum WorkspaceSceneSequence {
  private static var nextWindowValue = 1
  private static var nextUnsavedValue = 1

  static func nextWindow() -> Int {
    defer { nextWindowValue += 1 }
    return nextWindowValue
  }

  static func nextUnsaved() -> Int {
    defer { nextUnsavedValue += 1 }
    return nextUnsavedValue
  }

  static func reserve(window: Int, unsaved: Int?) {
    nextWindowValue = max(nextWindowValue, window + 1)
    if let unsaved {
      nextUnsavedValue = max(nextUnsavedValue, unsaved + 1)
    }
  }
}

private struct LauncherView: View {
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow
  @State private var didOpenUITestingWorkspace = false
  @State private var didOpenRecordingPreviewFixture = false

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "video.badge.waveform")
        .font(.system(size: 44))
        .foregroundStyle(.tint)
      Text("LDTX")
        .font(.largeTitle.bold())
      HStack(spacing: 12) {
        Button("New Workspace") {
          openWorkspace(.new())
        }
        .keyboardShortcut(.defaultAction)

        Button("Open File…") {
          chooseFileToOpen()
        }
      }
    }
    .padding(36)
    .task {
      guard LDTXRuntimeMode.isUITesting, !didOpenUITestingWorkspace else { return }
      didOpenUITestingWorkspace = true
      openWorkspace(.new())
    }
    .task {
      guard !didOpenRecordingPreviewFixture,
        let fixture = LDTXRuntimeMode.recordingPreviewFixture
      else { return }
      didOpenRecordingPreviewFixture = true
      openRecording(fixture.recordingURL)
    }
  }

  private func chooseFileToOpen() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.ldtxWorkspace, .ldtxRecording]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Open an LDTX Workspace or recording."
    panel.prompt = "Open"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    route(url.standardizedFileURL)
  }

  private func route(_ url: URL) {
    switch url.pathExtension.lowercased() {
    case WorkspacePackageLayout.pathExtension:
      openWorkspace(.file(url))
    case RecordingPackage.pathExtension:
      openRecording(url)
    default:
      return
    }
  }

  private func openWorkspace(_ request: WorkspaceEditorWindowRequest) {
    openWindow(id: "workspace-editor", value: request)
    dismissWindow(id: "launcher")
  }

  private func openRecording(_ url: URL) {
    openWindow(id: "recording-preview", value: url.standardizedFileURL)
    dismissWindow(id: "launcher")
  }
}

private struct ApplicationRouterInstaller: ViewModifier {
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow
  let applicationRouter: LDTXApplicationRouter

  func body(content: Content) -> some View {
    content.task {
      applicationRouter.launcherOpenCoordinator.installOpenHandler {
        openWindow(id: "launcher")
      }
      applicationRouter.workspaceOpenCoordinator.installOpenHandler { url in
        openWindow(id: "workspace-editor", value: WorkspaceEditorWindowRequest.file(url))
        dismissWindow(id: "launcher")
      }
      applicationRouter.recordingOpenCoordinator.installOpenHandler { url in
        openWindow(id: "recording-preview", value: url.standardizedFileURL)
        dismissWindow(id: "launcher")
      }
    }
  }
}

private struct ApplicationFileCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  private var diagnosticReportsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Workspace") {
        openWindow(id: "workspace-editor", value: WorkspaceEditorWindowRequest.new())
      }
      .keyboardShortcut("n", modifiers: .command)

      Button("Open File…") {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.ldtxWorkspace, .ldtxRecording]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open an LDTX Workspace or recording."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let standardizedURL = url.standardizedFileURL
        switch standardizedURL.pathExtension.lowercased() {
        case WorkspacePackageLayout.pathExtension:
          openWindow(id: "workspace-editor", value: WorkspaceEditorWindowRequest.file(standardizedURL))
        case RecordingPackage.pathExtension:
          openWindow(id: "recording-preview", value: standardizedURL)
        default:
          return
        }
      }
      .keyboardShortcut("o", modifiers: .command)
    }

    CommandGroup(replacing: .saveItem) {
      Button("Save") {
        WorkspaceCommandCoordinator.shared.activeActions?.saveWorkspace()
      }
      .keyboardShortcut("s", modifiers: .command)

      Button("Save As...") {
        WorkspaceCommandCoordinator.shared.activeActions?.saveWorkspaceAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }

    CommandGroup(after: .help) {
      Button("Show Crash Reports in Finder") {
        NSWorkspace.shared.open(diagnosticReportsDirectory)
      }
    }
  }
}

extension UTType {
  fileprivate static let ldtxRecording = UTType(exportedAs: "tokyo.kaito.ldtx.recording")
}
