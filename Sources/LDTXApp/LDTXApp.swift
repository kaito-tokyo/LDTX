// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXRecording
import LDTXYouTubeAuth
import SwiftUI
import UniformTypeIdentifiers

struct LDTXApp: App {
  @StateObject private var oauthClientState: OAuthClientState
  @StateObject private var authState: YouTubeAuthState
  private let youtubeClientService: YouTubeClientService

  init() {
    let youtubeClientService = YouTubeClientService()
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
    Window("LDTX", id: "main") {
      MainWindowContent(
        oauthClientState: oauthClientState,
        authState: authState,
        youtubeClientService: youtubeClientService
      )
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      WorkspaceCommands()
      RecordingPreviewCommands()
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
    }
  }
}

private struct MainWindowContent: View {
  @State private var didOpenRecordingPreviewFixture = false

  let oauthClientState: OAuthClientState
  let authState: YouTubeAuthState
  let youtubeClientService: YouTubeClientService

  var body: some View {
    WorkspaceContainer(
      oauthClientState: oauthClientState,
      authState: authState,
      youtubeClientService: youtubeClientService
    )
    .onOpenURL { url in
      guard url.isFileURL,
        url.pathExtension.lowercased() == RecordingPackage.pathExtension
      else { return }
      RecordingPreviewWindowManager.shared.open(recordingURL: url)
    }
    .task {
      guard !didOpenRecordingPreviewFixture,
        let fixture = LDTXRuntimeMode.recordingPreviewFixture
      else { return }
      didOpenRecordingPreviewFixture = true
      try? await Task.sleep(for: .seconds(1))
      RecordingPreviewWindowManager.shared.open(recordingURL: fixture.recordingURL)
    }
  }
}

extension UTType {
  fileprivate static let ldtxRecording = UTType(exportedAs: "tokyo.kaito.ldtx.recording")
}

private struct RecordingPreviewCommands: Commands {
  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open Recording...") {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.ldtxRecording]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open an LDTX recording to preview it."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingPreviewWindowManager.shared.open(recordingURL: url)
      }
      .keyboardShortcut("o", modifiers: [.command, .option])
    }
  }
}
