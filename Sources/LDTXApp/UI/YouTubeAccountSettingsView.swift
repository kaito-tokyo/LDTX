// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

struct YouTubeAccountSettingsView: View {
    @ObservedObject var oauthClientState: OAuthClientState
    @ObservedObject var authState: YouTubeAuthState

    var body: some View {
        Form {
            Section("YouTube Account") {
                LabeledContent("OAuth") {
                    Text(oauthClientState.status)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Authorization") {
                    Text(authState.status)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        oauthClientState.isImportingOAuthClient = true
                    } label: {
                        Label("Import OAuth Client", systemImage: "doc.badge.plus")
                    }

                    Button {
                        authState.authorize(configuration: oauthClientState.configuration)
                    } label: {
                        Label("Authorize YouTube", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(oauthClientState.configuration == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            authState.restore(for: oauthClientState.configuration)
        }
        .fileImporter(isPresented: $oauthClientState.isImportingOAuthClient, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result,
               let configuration = oauthClientState.load(from: url) {
                authState.restore(for: configuration)
            }
        }
    }
}
