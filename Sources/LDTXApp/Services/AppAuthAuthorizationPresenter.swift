// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
@preconcurrency import AppAuth
import Foundation

@MainActor
final class AppAuthAuthorizationPresenter {
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?

    func authorize(request: OIDAuthorizationRequest) async throws -> OIDAuthState {
        guard let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first else {
            throw AppAuthAuthorizationPresenterError.missingPresentationWindow
        }

        let externalUserAgent = OIDExternalUserAgentMac(presenting: window)
        return try await withCheckedThrowingContinuation { continuation in
            currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: externalUserAgent
            ) { [weak self] authState, error in
                self?.currentAuthorizationFlow = nil
                if let authState {
                    continuation.resume(returning: authState)
                } else {
                    continuation.resume(throwing: error ?? AppAuthAuthorizationPresenterError.missingAuthState)
                }
            }
        }
    }
}

enum AppAuthAuthorizationPresenterError: Error, LocalizedError {
    case missingPresentationWindow
    case missingAuthState

    var errorDescription: String? {
        switch self {
        case .missingPresentationWindow:
            "A window is required to present the OAuth authentication session."
        case .missingAuthState:
            "The OAuth authentication session completed without an authorization state."
        }
    }
}
