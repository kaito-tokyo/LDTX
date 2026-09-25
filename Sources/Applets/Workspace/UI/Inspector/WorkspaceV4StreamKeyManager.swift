// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletService
import LDTXYouTubeRTMPS
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceV4StreamKeyManager: View {
  @Environment(\.dismiss) private var dismiss
  @State private var drafts: [YouTubeRTMPSStreamKeyConfiguration]
  let load: () throws -> [YouTubeRTMPSStreamKeyConfiguration]
  let save: ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void
  @State private var errorMessage: String?

  init(
    configurations: [YouTubeRTMPSStreamKeyConfiguration],
    load: @escaping () throws -> [YouTubeRTMPSStreamKeyConfiguration],
    save: @escaping ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void
  ) {
    _drafts = State(initialValue: configurations)
    self.load = load
    self.save = save
  }

  var body: some View {
    NavigationStack {
      Form {
        Button("Add Configuration") { drafts.append(.init()) }
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
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle("Manage Stream Keys")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try save(drafts)
              dismiss()
            } catch { errorMessage = "The stream key configurations could not be saved." }
          }
        }
      }
    }
    .frame(minWidth: 520, minHeight: 360)
    .onAppear {
      do { drafts = try load() } catch {
        errorMessage = "The stream key configurations could not be loaded."
      }
    }
  }
}
