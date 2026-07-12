// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
@preconcurrency import AppAuth
import Foundation

@MainActor
final class AppAuthAuthorizationPresenter {
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?

    func authorize(
        request: OIDAuthorizationRequest,
        completionHandler: @escaping @MainActor @Sendable (Result<OIDAuthState, any Error>) -> Void
    ) {
        guard currentAuthorizationFlow == nil else {
            completionHandler(.failure(AppAuthAuthorizationPresenterError.authorizationAlreadyInProgress))
            return
        }
        guard let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first else {
            completionHandler(.failure(AppAuthAuthorizationPresenterError.missingPresentationWindow))
            return
        }

        let externalUserAgent = OIDExternalUserAgentMac(presenting: window)
        currentAuthorizationFlow = OIDAuthState.authState(
            byPresenting: request,
            externalUserAgent: externalUserAgent
        ) { [weak self] authState, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.currentAuthorizationFlow = nil
                    if let authState {
                        completionHandler(.success(authState))
                    } else {
                        completionHandler(.failure(
                            error ?? AppAuthAuthorizationPresenterError.missingAuthState
                        ))
                    }
                }
            }
        }
    }
}

enum AppAuthAuthorizationPresenterError: Error, LocalizedError {
    case missingPresentationWindow
    case missingAuthState
    case authorizationAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .missingPresentationWindow:
            "A window is required to present the OAuth authentication session."
        case .missingAuthState:
            "The OAuth authentication session completed without an authorization state."
        case .authorizationAlreadyInProgress:
            "A YouTube authorization session is already in progress."
        }
    }
}
