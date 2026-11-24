// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import SwiftUI

/// The Settings tab that adds, edits and deletes YouTube RTMPS stream key configurations.
///
/// Configurations are edited one at a time in a sheet and saved to the Keychain when the
/// sheet's Save button succeeds. With an importer, a configuration can also be retrieved from
/// one of the authorized channel's YouTube LiveStreams. Workspaces choose which configuration
/// they use in their Output inspector.
public struct YouTubeStreamKeySettingsView: View {
  @State private var model: YouTubeStreamKeySettingsModel
  @State private var editingDraft: YouTubeStreamKeyEditorDraft?
  @State private var pendingDeletion: YouTubeRTMPSStreamKeyConfiguration?
  @State private var errorMessage: String?
  @State private var isShowingImport = false
  private let importer: YouTubeStreamKeyImporter?

  public init(
    appletData: WorkspaceAppletData = .shared, importer: YouTubeStreamKeyImporter? = nil
  ) {
    _model = State(initialValue: YouTubeStreamKeySettingsModel(appletData: appletData))
    self.importer = importer
  }

  public var body: some View {
    Form {
      Section {
        if let loadErrorMessage = model.loadErrorMessage {
          HStack {
            Label(loadErrorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
            Spacer()
            Button("Try Again", action: model.reload)
          }
        } else if model.configurations.isEmpty {
          Text("No stream keys. Add one to stream to YouTube over RTMPS.")
            .foregroundStyle(.secondary)
        }
        ForEach(model.configurations) { configuration in
          row(for: configuration)
        }
      } header: {
        Text("YouTube RTMPS Stream Keys")
      } footer: {
        Text(
          "Stream keys are stored in the Keychain on this Mac and shared by all Workspaces. Choose the stream keys each Workspace uses in its Output inspector."
        )
        .foregroundStyle(.secondary)
      }
      Section {
        HStack {
          Button("Add Stream Key…", systemImage: "plus") {
            errorMessage = nil
            editingDraft = YouTubeStreamKeyEditorDraft(configuration: .init(), isNew: true)
          }
          .disabled(model.loadErrorMessage != nil)
          if importer != nil {
            Button("Import from YouTube…", systemImage: "square.and.arrow.down") {
              errorMessage = nil
              isShowingImport = true
            }
            .disabled(model.loadErrorMessage != nil)
          }
          Spacer()
        }
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: model.reload)
    .sheet(isPresented: $isShowingImport) {
      if let importer {
        YouTubeStreamKeyImportSheet(
          importer: importer,
          importedLiveStreamIDs: Set(model.configurations.compactMap(\.sourceLiveStreamID)),
          store: { try model.importConfiguration($0) })
      }
    }
    .sheet(item: $editingDraft) { draft in
      YouTubeStreamKeyEditor(
        draft: draft,
        validationMessage: {
          YouTubeStreamKeySettingsModel.validationMessage(for: $0, among: model.configurations)
        },
        save: { try model.save($0) }
      )
    }
    .confirmationDialog(
      "Delete “\(pendingDeletion?.name ?? "")”?",
      isPresented: Binding(
        get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
      presenting: pendingDeletion
    ) { configuration in
      Button("Delete", role: .destructive) { delete(configuration) }
    } message: { _ in
      Text(
        "The stream key is removed from the Keychain. Workspaces that use it show it as unavailable until another stream key is chosen."
      )
    }
  }

  private func row(for configuration: YouTubeRTMPSStreamKeyConfiguration) -> some View {
    HStack {
      VStack(alignment: .leading) {
        Text(configuration.name)
        Text(
          configuration.sourceLiveStreamID == nil
            ? configuration.streamURL
            : String(localized: "From YouTube · \(configuration.streamURL)")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }
      Spacer()
      Button("Edit…") { edit(configuration) }
      Button("Delete", systemImage: "trash", role: .destructive) {
        pendingDeletion = configuration
      }
      .labelStyle(.iconOnly)
      .help("Delete")
    }
    .contextMenu {
      Button("Edit…") { edit(configuration) }
      Button("Delete…", role: .destructive) { pendingDeletion = configuration }
    }
  }

  private func edit(_ configuration: YouTubeRTMPSStreamKeyConfiguration) {
    errorMessage = nil
    editingDraft = YouTubeStreamKeyEditorDraft(configuration: configuration, isNew: false)
  }

  private func delete(_ configuration: YouTubeRTMPSStreamKeyConfiguration) {
    pendingDeletion = nil
    do {
      try model.delete(id: configuration.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct YouTubeStreamKeyEditorDraft: Identifiable {
  let id = UUID()
  var configuration: YouTubeRTMPSStreamKeyConfiguration
  let isNew: Bool
}

/// The sheet that edits one stream key configuration. Cancel discards the draft; Save keeps
/// the sheet open and shows the error when the configuration cannot be saved.
struct YouTubeStreamKeyEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var configuration: YouTubeRTMPSStreamKeyConfiguration
  @State private var saveErrorMessage: String?
  private let isNew: Bool
  private let validationMessage: (YouTubeRTMPSStreamKeyConfiguration) -> String?
  private let save: (YouTubeRTMPSStreamKeyConfiguration) throws -> Void

  init(
    draft: YouTubeStreamKeyEditorDraft,
    validationMessage: @escaping (YouTubeRTMPSStreamKeyConfiguration) -> String?,
    save: @escaping (YouTubeRTMPSStreamKeyConfiguration) throws -> Void
  ) {
    _configuration = State(initialValue: draft.configuration)
    isNew = draft.isNew
    self.validationMessage = validationMessage
    self.save = save
  }

  var body: some View {
    let problem = validationMessage(configuration)
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $configuration.name, prompt: Text("Main Channel"))
          TextField(
            "Stream URL", text: $configuration.streamURL,
            prompt: Text("rtmps://a.rtmps.youtube.com/live2"))
          TextField(
            "Backup Server URL", text: $configuration.backupServerURL,
            prompt: Text("Optional"))
          SecureField("Stream Key", text: $configuration.streamKey)
        } header: {
          Text(isNew ? "Add Stream Key" : "Edit Stream Key")
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              "Copy the stream URL, backup server URL and stream key from YouTube Studio. The backup server URL is stored but not used for publishing yet."
            )
            .foregroundStyle(.secondary)
            if let problem {
              Text(problem).foregroundStyle(.secondary)
            }
            if let saveErrorMessage {
              Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            }
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          do {
            try save(configuration)
            dismiss()
          } catch {
            saveErrorMessage = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
      }
      .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 480)
  }
}

/// The sheet that lists the authorized channel's LiveStreams and imports one as a stream key
/// configuration. Importing a LiveStream that was imported before refreshes that configuration.
struct YouTubeStreamKeyImportSheet: View {
  private enum Phase {
    case loading
    case loaded([YouTubeStreamKeyImportCandidate])
    case failed(String)
  }

  @Environment(\.dismiss) private var dismiss
  @State private var phase = Phase.loading
  @State private var selection: YouTubeStreamKeyImportCandidate.ID?
  @State private var isImporting = false
  @State private var importErrorMessage: String?
  let importer: YouTubeStreamKeyImporter
  let importedLiveStreamIDs: Set<String>
  let store: (YouTubeRTMPSStreamKeyConfiguration) throws -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import from YouTube").font(.headline)
      Text(
        "Choose a stream from the YouTube account authorized in the Account tab. Its stream URL and stream key are saved to the Keychain. Importing a stream again updates its saved key."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      content
        .frame(minHeight: 200, maxHeight: .infinity)
      if let importErrorMessage {
        Label(importErrorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Reload") { Task { await load() } }
          .disabled(isLoading || isImporting)
        Spacer()
        if isImporting { ProgressView().controlSize(.small) }
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Import", action: importSelection)
          .keyboardShortcut(.defaultAction)
          .disabled(selectedCandidate?.supportsRTMPS != true || isImporting)
      }
    }
    .padding(20)
    .frame(width: 480, height: 420)
    .interactiveDismissDisabled(isImporting)
    .task { await load() }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .loading:
      ProgressView("Loading Streams…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      VStack {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        Text("Authorize YouTube in the Account tab, then reload.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let candidates) where candidates.isEmpty:
      Text("The authorized channel has no streams. Create a stream in YouTube Studio first.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let candidates):
      List(candidates, selection: $selection) { candidate in
        HStack {
          VStack(alignment: .leading) {
            Text(candidate.title)
            if let status = candidate.status {
              Text(status).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if !candidate.supportsRTMPS {
            Text("No RTMPS").font(.caption).foregroundStyle(.secondary)
          } else if importedLiveStreamIDs.contains(candidate.id) {
            Text("Imported").font(.caption).foregroundStyle(.secondary)
          }
        }
        .foregroundStyle(candidate.supportsRTMPS ? .primary : .secondary)
        .tag(candidate.id)
      }
      .listStyle(.bordered)
    }
  }

  private var isLoading: Bool {
    if case .loading = phase { return true }
    return false
  }

  private var selectedCandidate: YouTubeStreamKeyImportCandidate? {
    guard case .loaded(let candidates) = phase else { return nil }
    return candidates.first { $0.id == selection }
  }

  private func load() async {
    phase = .loading
    importErrorMessage = nil
    do {
      let candidates = try await importer.listCandidates()
      phase = .loaded(candidates)
      if !candidates.contains(where: { $0.id == selection }) { selection = nil }
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func importSelection() {
    guard let candidate = selectedCandidate, candidate.supportsRTMPS, !isImporting else { return }
    isImporting = true
    importErrorMessage = nil
    Task {
      defer { isImporting = false }
      do {
        try store(try await importer.retrieveConfiguration(candidate.id))
        dismiss()
      } catch {
        importErrorMessage = error.localizedDescription
      }
    }
  }
}

#if DEBUG
  import Security

  #Preview("Stream Keys") {
    YouTubeStreamKeySettingsView(
      appletData: WorkspaceAppletData(
        userDefaults: UserDefaults(suiteName: "YouTubeStreamKeySettingsPreview.\(UUID())")!,
        streamKeyKeychainOperations: DataProtectionKeychainItem.Operations(
          copyMatching: { _, _ in errSecItemNotFound },
          add: { _, _ in errSecSuccess },
          update: { _, _ in errSecItemNotFound },
          delete: { _ in errSecItemNotFound }))
    )
    .frame(width: 560, height: 360)
  }
#endif
