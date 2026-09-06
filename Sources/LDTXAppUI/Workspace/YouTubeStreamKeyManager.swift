// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTubeRTMPS
import SwiftUI

struct YouTubeStreamKeyManager: View {
  let existingLiveStreams: [LiveStreamSummary]
  let isLoading: Bool
  let refresh: () -> Void
  let importConfiguration: (String) async throws -> YouTubeRTMPSStreamKeyConfiguration
  let save: ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void
  @State private var drafts: [YouTubeRTMPSStreamKeyConfiguration]
  @State private var errorMessage: String?
  @State private var isImporting = false
  @Environment(\.dismiss) private var dismiss

  init(
    configurations: [YouTubeRTMPSStreamKeyConfiguration],
    existingLiveStreams: [LiveStreamSummary], isLoading: Bool,
    refresh: @escaping () -> Void,
    importConfiguration: @escaping (String) async throws -> YouTubeRTMPSStreamKeyConfiguration,
    save: @escaping ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void
  ) {
    _drafts = State(initialValue: configurations)
    self.existingLiveStreams = existingLiveStreams
    self.isLoading = isLoading
    self.refresh = refresh
    self.importConfiguration = importConfiguration
    self.save = save
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button("Add Configuration") { drafts.append(.init()) }
          Menu("Import from YouTube") {
            Button("Load Available Stream Keys", action: refresh)
              .disabled(isLoading)
            ForEach(existingLiveStreams) { stream in
              Button(stream.title) {
                isImporting = true
                errorMessage = nil
                Task { @MainActor in
                  defer { isImporting = false }
                  do { drafts.append(try await importConfiguration(stream.id)) } catch {
                    errorMessage =
                      "The stream key configuration could not be retrieved from YouTube."
                  }
                }
              }
            }
          }
          .disabled(isImporting)
          if isLoading || isImporting { ProgressView("Loading Stream Keys") }
        }
        ForEach($drafts) { $configuration in
          Section {
            TextField("Name", text: $configuration.name)
            TextField("Stream URL", text: $configuration.streamURL)
            TextField("Backup Server URL", text: $configuration.backupServerURL)
            SecureField("Stream Key", text: $configuration.streamKey)
            Button("Delete Configuration", role: .destructive) {
              drafts.removeAll { $0.id == configuration.id }
            }
          }
          .onChange(of: configuration.streamURL) { _, _ in configuration.sourceLiveStreamID = nil }
          .onChange(of: configuration.backupServerURL) { _, _ in
            configuration.sourceLiveStreamID = nil
          }
          .onChange(of: configuration.streamKey) { _, _ in configuration.sourceLiveStreamID = nil }
        }
        if !drafts.isEmpty {
          Text(
            "Enter an RTMPS stream URL and stream key for each configuration. The backup server URL is optional."
          )
          .font(.caption)
        }
        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Manage Stream Keys")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(isImporting)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try save(drafts)
              dismiss()
            } catch {
              errorMessage =
                "The configurations could not be saved. Check the URLs, keys, and Keychain access."
            }
          }
          .disabled(isImporting || drafts.contains { (try? $0.destination()) == nil })
        }
      }
    }
    .frame(minWidth: 560, minHeight: 420)
    .interactiveDismissDisabled(isImporting)
  }
}
