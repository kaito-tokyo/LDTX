// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

public struct YouTubeAccountSettingsView: View {
    private var oauthStatus: String
    private var authorizationStatus: String
    @Binding private var isImportingOAuthClient: Bool
    private var canAuthorize: Bool
    private var restoreAuthorization: () -> Void
    private var authorizeYouTube: () -> Void
    private var loadOAuthClient: (URL) -> Bool

    public init(
        oauthStatus: String,
        authorizationStatus: String,
        isImportingOAuthClient: Binding<Bool>,
        canAuthorize: Bool,
        restoreAuthorization: @escaping () -> Void,
        authorizeYouTube: @escaping () -> Void,
        loadOAuthClient: @escaping (URL) -> Bool
    ) {
        self.oauthStatus = oauthStatus
        self.authorizationStatus = authorizationStatus
        _isImportingOAuthClient = isImportingOAuthClient
        self.canAuthorize = canAuthorize
        self.restoreAuthorization = restoreAuthorization
        self.authorizeYouTube = authorizeYouTube
        self.loadOAuthClient = loadOAuthClient
    }

    public var body: some View {
        Form {
            Section("YouTube Account") {
                LabeledContent("OAuth") {
                    Text(oauthStatus)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Authorization") {
                    Text(authorizationStatus)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        isImportingOAuthClient = true
                    } label: {
                        Label("Import OAuth Client", systemImage: "doc.badge.plus")
                    }

                    Button {
                        authorizeYouTube()
                    } label: {
                        Label("Authorize YouTube", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(!canAuthorize)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            restoreAuthorization()
        }
        .fileImporter(isPresented: $isImportingOAuthClient, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result,
               loadOAuthClient(url) {
                restoreAuthorization()
            }
        }
    }
}

#if DEBUG
#Preview("YouTube Account Settings") {
    @Previewable @State var isImportingOAuthClient = false

    YouTubeAccountSettingsView(
        oauthStatus: LDTXAppUIPreviewFixtures.oauthClientStatus,
        authorizationStatus: LDTXAppUIPreviewFixtures.authorizationStatus,
        isImportingOAuthClient: $isImportingOAuthClient,
        canAuthorize: true,
        restoreAuthorization: {},
        authorizeYouTube: {},
        loadOAuthClient: { _ in true }
    )
}
#endif
