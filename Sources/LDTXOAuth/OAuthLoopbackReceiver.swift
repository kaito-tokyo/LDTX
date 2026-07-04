// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

public struct OAuthRedirectResult: Equatable, Sendable {
    public var code: String
    public var state: String?

    public init(code: String, state: String?) {
        self.code = code
        self.state = state
    }
}

public enum OAuthLoopbackReceiverError: Error, Equatable, LocalizedError {
    case invalidPort(UInt16)
    case invalidRequest
    case authorizationDenied(String)
    case missingCode
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            "Invalid loopback port: \(port)."
        case .invalidRequest:
            "The OAuth loopback receiver got an invalid HTTP request."
        case let .authorizationDenied(message):
            "Authorization was denied: \(message)"
        case .missingCode:
            "The OAuth redirect did not include an authorization code."
        case let .listenerFailed(message):
            "The OAuth loopback receiver failed: \(message)"
        }
    }
}

public final class OAuthLoopbackReceiver: @unchecked Sendable {
    public let redirectURI: URL

    private let listener: NWListener
    private let callbackPath: String
    private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.OAuthLoopbackReceiver")

    public init(port: UInt16 = 53_682, callbackPath: String = "/oauth2/callback") throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OAuthLoopbackReceiverError.invalidPort(port)
        }
        self.listener = try NWListener(using: .tcp, on: nwPort)
        self.callbackPath = callbackPath
        self.redirectURI = URL(string: "http://127.0.0.1:\(port)\(callbackPath)")!
    }

    public func receive() async throws -> OAuthRedirectResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = OAuthLoopbackContinuation(continuation: continuation)

            listener.stateUpdateHandler = { newState in
                if case let .failed(error) = newState {
                    state.resume(throwing: OAuthLoopbackReceiverError.listenerFailed(error.localizedDescription))
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection, state: state)
            }
            listener.start(queue: queue)
        }
    }

    public func cancel() {
        listener.cancel()
    }

    private func handle(connection: NWConnection, state: OAuthLoopbackContinuation) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.sendResponse(status: 500, body: "OAuth callback failed.", connection: connection)
                state.resume(throwing: OAuthLoopbackReceiverError.listenerFailed(error.localizedDescription))
                self.listener.cancel()
                return
            }

            do {
                guard let data, let request = String(data: data, encoding: .utf8) else {
                    throw OAuthLoopbackReceiverError.invalidRequest
                }
                let result = try self.parse(request: request)
                self.sendResponse(status: 200, body: "Authorization complete. You can return to LDTX.", connection: connection)
                state.resume(returning: result)
            } catch {
                self.sendResponse(status: 400, body: "Authorization failed.", connection: connection)
                state.resume(throwing: error)
            }
            self.listener.cancel()
        }
    }

    private func parse(request: String) throws -> OAuthRedirectResult {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            throw OAuthLoopbackReceiverError.invalidRequest
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] == "GET" else {
            throw OAuthLoopbackReceiverError.invalidRequest
        }

        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == callbackPath else {
            throw OAuthLoopbackReceiverError.invalidRequest
        }

        let queryItems = components.queryItems ?? []
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw OAuthLoopbackReceiverError.authorizationDenied(error)
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthLoopbackReceiverError.missingCode
        }
        let state = queryItems.first(where: { $0.name == "state" })?.value
        return OAuthRedirectResult(code: code, state: state)
    }

    private func sendResponse(status: Int, body: String, connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Bad Request"
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        let response = Data(header.utf8) + bodyData
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class OAuthLoopbackContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<OAuthRedirectResult, Error>

    init(continuation: CheckedContinuation<OAuthRedirectResult, Error>) {
        self.continuation = continuation
    }

    func resume(returning result: OAuthRedirectResult) {
        resume { continuation.resume(returning: result) }
    }

    func resume(throwing error: Error) {
        resume { continuation.resume(throwing: error) }
    }

    private func resume(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        operation()
    }
}
