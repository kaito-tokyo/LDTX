// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import AppKit
import Foundation

@MainActor
final class AppAuthAuthorizationPresenter {
  private var currentAuthorizationFlow: OIDExternalUserAgentSession?
  private var redirectHTTPHandler: OIDRedirectHTTPHandler?

  func authorize(
    requestBuilder: (URL) throws -> OIDAuthorizationRequest,
    completionHandler: @escaping @MainActor @Sendable (Result<OIDAuthState, any Error>) -> Void
  ) {
    guard currentAuthorizationFlow == nil else {
      completionHandler(.failure(AppAuthAuthorizationPresenterError.authorizationAlreadyInProgress))
      return
    }
    guard
      let window = NSApplication.shared.keyWindow
        ?? NSApplication.shared.mainWindow
        ?? NSApplication.shared.windows.first
    else {
      completionHandler(.failure(AppAuthAuthorizationPresenterError.missingPresentationWindow))
      return
    }

    let redirectHTTPHandler = OIDRedirectHTTPHandler(successURL: nil)
    var listenerError: NSError?
    guard
      let listenerURL = redirectHTTPHandler.startHTTPListener(&listenerError) as URL?
    else {
      completionHandler(
        .failure(listenerError ?? AppAuthAuthorizationPresenterError.loopbackListenerStartFailed)
      )
      return
    }
    let redirectURI: URL
    do {
      redirectURI = try LoopbackOAuthRedirect.validate(listenerURL: listenerURL)
    } catch {
      redirectHTTPHandler.cancelHTTPListener()
      completionHandler(.failure(error))
      return
    }

    let request: OIDAuthorizationRequest
    do {
      request = try requestBuilder(redirectURI)
    } catch {
      redirectHTTPHandler.cancelHTTPListener()
      completionHandler(.failure(error))
      return
    }

    let externalUserAgent = OIDExternalUserAgentMac(presenting: window)
    self.redirectHTTPHandler = redirectHTTPHandler
    let authorizationFlow = OIDAuthState.authState(
      byPresenting: request,
      externalUserAgent: externalUserAgent
    ) { [weak self] authState, error in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.currentAuthorizationFlow = nil
          self?.redirectHTTPHandler?.cancelHTTPListener()
          self?.redirectHTTPHandler = nil
          if let authState {
            completionHandler(.success(authState))
          } else {
            completionHandler(
              .failure(
                error ?? AppAuthAuthorizationPresenterError.missingAuthState
              ))
          }
        }
      }
    }
    currentAuthorizationFlow = authorizationFlow
    redirectHTTPHandler.currentAuthorizationFlow = authorizationFlow
  }

  func cancelAuthorization() {
    guard let currentAuthorizationFlow else {
      redirectHTTPHandler?.cancelHTTPListener()
      return
    }
    currentAuthorizationFlow.cancel { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.redirectHTTPHandler?.cancelHTTPListener()
        }
      }
    }
  }
}

enum LoopbackOAuthRedirect {
  static func validate(listenerURL: URL) throws -> URL {
    guard listenerURL.scheme == "http", listenerURL.host == "127.0.0.1",
      listenerURL.port != nil
    else {
      throw AppAuthAuthorizationPresenterError.ipv4LoopbackUnavailable
    }
    return listenerURL
  }
}

enum AppAuthAuthorizationPresenterError: Error, LocalizedError {
  case missingPresentationWindow
  case missingAuthState
  case authorizationAlreadyInProgress
  case ipv4LoopbackUnavailable
  case loopbackListenerStartFailed

  var errorDescription: String? {
    switch self {
    case .missingPresentationWindow:
      "A window is required to present the OAuth authentication session."
    case .missingAuthState:
      "The OAuth authentication session completed without an authorization state."
    case .authorizationAlreadyInProgress:
      "A YouTube authorization session is already in progress."
    case .ipv4LoopbackUnavailable:
      "The OAuth loopback listener could not bind to 127.0.0.1."
    case .loopbackListenerStartFailed:
      "The OAuth loopback listener could not be started."
    }
  }
}
