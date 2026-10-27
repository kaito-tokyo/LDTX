// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class LoopbackOAuthAuthorizationPresenter {
  struct AuthorizationGrant: Sendable {
    var code: String
    var codeVerifier: String
    var redirectURI: URL
  }

  private var listener: NWListener?
  private var authorizationState: String?
  private var codeVerifier: String?
  private var redirectURI: URL?
  private var requestBuilder: (@MainActor (URL, String, String) throws -> URL)?
  private var completionHandler:
    (@MainActor @Sendable (Result<AuthorizationGrant, any Error>) -> Void)?

  func authorize(
    requestBuilder: @escaping @MainActor (URL, String, String) throws -> URL,
    completionHandler:
      @escaping @MainActor @Sendable (Result<AuthorizationGrant, any Error>) -> Void
  ) {
    guard self.completionHandler == nil else {
      completionHandler(.failure(LoopbackOAuthAuthorizationError.authorizationAlreadyInProgress))
      return
    }
    let presentationWindow =
      NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
      ?? NSApplication.shared.windows.first
    guard presentationWindow != nil else {
      completionHandler(.failure(LoopbackOAuthAuthorizationError.missingPresentationWindow))
      return
    }

    do {
      let state = try Self.randomURLSafeString(byteCount: 32)
      let verifier = try Self.randomURLSafeString(byteCount: 32)
      let challenge = Self.base64URL(SHA256.hash(data: Data(verifier.utf8)))
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
      parameters.acceptLocalOnly = true
      let listener = try NWListener(using: parameters, on: .any)
      self.authorizationState = state
      self.codeVerifier = verifier
      self.requestBuilder = requestBuilder
      self.completionHandler = completionHandler
      self.listener = listener
      listener.stateUpdateHandler = { [weak self] state in
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          MainActor.assumeIsolated { self.listenerDidUpdate(state) }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          MainActor.assumeIsolated { self.receiveCallback(on: connection) }
        }
      }
      listener.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
        guard let self, self.completionHandler != nil else { return }
        self.finish(.failure(LoopbackOAuthAuthorizationError.authorizationTimedOut))
      }
    } catch {
      completionHandler(.failure(error))
    }
  }

  func cancelAuthorization() {
    guard completionHandler != nil else { return }
    finish(.failure(LoopbackOAuthAuthorizationError.authorizationCancelled))
  }

  private func listenerDidUpdate(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let listener, let port = listener.port,
        let authorizationState, let codeVerifier, let requestBuilder
      else {
        finish(.failure(LoopbackOAuthAuthorizationError.loopbackListenerStartFailed))
        return
      }
      guard let redirectURI = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback") else {
        finish(.failure(LoopbackOAuthAuthorizationError.invalidLoopbackRedirect))
        return
      }
      do {
        _ = try LoopbackOAuthRedirect.validate(listenerURL: redirectURI)
        let challenge = Self.base64URL(SHA256.hash(data: Data(codeVerifier.utf8)))
        let authorizationURL = try requestBuilder(redirectURI, authorizationState, challenge)
        guard NSWorkspace.shared.open(authorizationURL) else {
          finish(.failure(LoopbackOAuthAuthorizationError.browserCouldNotBeOpened))
          return
        }
        self.redirectURI = redirectURI
      } catch {
        finish(.failure(error))
      }
    case .failed:
      finish(.failure(LoopbackOAuthAuthorizationError.loopbackListenerStartFailed))
    case .cancelled, .setup, .waiting:
      break
    @unknown default:
      finish(.failure(LoopbackOAuthAuthorizationError.loopbackListenerStartFailed))
    }
  }

  private func receiveCallback(on connection: NWConnection) {
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, _, error in
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          connection.cancel()
          return
        }
        MainActor.assumeIsolated {
          guard error == nil, let data, let request = String(data: data, encoding: .utf8),
            let outcome = self.parseCallback(request)
          else {
            self.sendResponse(
              on: connection, status: 400, message: "Invalid authorization response.")
            return
          }
          switch outcome {
          case .invalidState:
            self.sendResponse(
              on: connection, status: 400, message: "Invalid authorization response.")
          case .failure(let error):
            self.sendResponse(
              on: connection, status: 400, message: "Authorization was not completed.")
            self.finish(.failure(error))
          case .success(let code):
            self.sendResponse(
              on: connection, status: 200,
              message: "Authorization received. You can return to LDTX.")
            guard let verifier = self.codeVerifier, let redirectURI = self.redirectURI else {
              self.finish(.failure(LoopbackOAuthAuthorizationError.missingAuthorizationCode))
              return
            }
            self.finish(
              .success(
                AuthorizationGrant(
                  code: code, codeVerifier: verifier, redirectURI: redirectURI)))
          }
        }
      }
    }
  }

  private enum CallbackOutcome {
    case invalidState
    case failure(any Error)
    case success(String)
  }

  private func parseCallback(_ request: String) -> CallbackOutcome? {
    let lines = request.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count == 3, parts[0] == "GET",
      let listenerPort = listener?.port?.rawValue,
      lines.dropFirst().contains(where: {
        $0.lowercased() == "host: 127.0.0.1:\(listenerPort)"
      }),
      let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
      components.path == "/oauth2callback"
    else { return nil }
    let items = components.queryItems ?? []
    guard let receivedState = items.first(where: { $0.name == "state" })?.value,
      let authorizationState, Self.constantTimeEqual(receivedState, authorizationState)
    else {
      return .invalidState
    }
    if let error = items.first(where: { $0.name == "error" })?.value {
      return .failure(LoopbackOAuthAuthorizationError.authorizationRejected(error))
    }
    guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
      return .failure(LoopbackOAuthAuthorizationError.missingAuthorizationCode)
    }
    return .success(code)
  }

  private func sendResponse(on connection: NWConnection, status: Int, message: String) {
    let body = "<!doctype html><meta charset=\"utf-8\"><title>LDTX</title><p>\(message)</p>"
    let bodyData = Data(body.utf8)
    let reason = status == 200 ? "OK" : "Bad Request"
    let headers =
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(bodyData.count)\r\n\r\n"
    var response = Data(headers.utf8)
    response.append(bodyData)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }

  private func finish(_ result: Result<AuthorizationGrant, any Error>) {
    listener?.cancel()
    listener = nil
    authorizationState = nil
    codeVerifier = nil
    redirectURI = nil
    requestBuilder = nil
    let completionHandler = self.completionHandler
    self.completionHandler = nil
    completionHandler?(result)
  }

  private static func randomURLSafeString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw LoopbackOAuthAuthorizationError.secureRandomUnavailable
    }
    return base64URL(Data(bytes))
  }

  private static func base64URL(_ data: some ContiguousBytes) -> String {
    data.withUnsafeBytes { Data($0).base64EncodedString() }
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

enum LoopbackOAuthAuthorizationError: Error, LocalizedError {
  case missingPresentationWindow
  case authorizationAlreadyInProgress
  case loopbackListenerStartFailed
  case browserCouldNotBeOpened
  case authorizationTimedOut
  case authorizationCancelled
  case missingAuthorizationCode
  case authorizationRejected(String)
  case secureRandomUnavailable
  case invalidLoopbackRedirect

  var errorDescription: String? {
    switch self {
    case .missingPresentationWindow:
      "A window is required to present the OAuth authentication session."
    case .authorizationAlreadyInProgress:
      "A YouTube authorization session is already in progress."
    case .loopbackListenerStartFailed:
      "The OAuth loopback listener could not be started."
    case .browserCouldNotBeOpened:
      "The system browser could not be opened for authorization."
    case .authorizationTimedOut:
      "The YouTube authorization session timed out."
    case .authorizationCancelled:
      "The YouTube authorization session was cancelled."
    case .missingAuthorizationCode:
      "The OAuth response did not contain an authorization code."
    case .authorizationRejected(let reason):
      "Google rejected the authorization request: \(reason)"
    case .secureRandomUnavailable:
      "A secure random value could not be generated for authorization."
    case .invalidLoopbackRedirect:
      "The OAuth callback URL must use the IPv4 loopback interface."
    }
  }
}

enum LoopbackOAuthRedirect {
  static func validate(listenerURL: URL) throws -> URL {
    guard listenerURL.scheme == "http", listenerURL.host == "127.0.0.1",
      listenerURL.port != nil, listenerURL.path == "/oauth2callback",
      listenerURL.user == nil, listenerURL.password == nil, listenerURL.fragment == nil
    else {
      throw LoopbackOAuthAuthorizationError.invalidLoopbackRedirect
    }
    return listenerURL
  }
}
