// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

protocol RTMPTransport: Sendable {
  func connect(host: String, port: UInt16) async throws
  func send(_ data: Data) async throws
  func receive(minimum: Int, maximum: Int) async throws -> Data
  func close() async
}

actor NetworkRTMPTransport: RTMPTransport {
  private var connection: NWConnection?

  func connect(host: String, port: UInt16) async throws {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_tls_server_name(
      tls.securityProtocolOptions, host)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: parameters)
    self.connection = connection
    try await withCheckedThrowingContinuation { continuation in
      let gate = ContinuationGate(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: gate.resume(returning: ())
        case .failed, .cancelled: gate.resume(throwing: YouTubeRTMPSError.connectionFailed)
        default: break
        }
      }
      connection.start(queue: DispatchQueue(label: "tokyo.kaito.ldtx.youtube-rtmps"))
    }
    connection.stateUpdateHandler = nil
  }

  func send(_ data: Data) async throws {
    guard let connection else { throw YouTubeRTMPSError.connectionFailed }
    try await withCheckedThrowingContinuation { continuation in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if error == nil {
            continuation.resume()
          } else {
            continuation.resume(throwing: YouTubeRTMPSError.connectionFailed)
          }
        })
    }
  }

  func receive(minimum: Int, maximum: Int) async throws -> Data {
    guard let connection else { throw YouTubeRTMPSError.connectionFailed }
    return try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) {
        data, _, complete, error in
        if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if error != nil || complete {
          continuation.resume(throwing: YouTubeRTMPSError.connectionFailed)
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  func close() async {
    connection?.cancel()
    connection = nil
  }
}

private final class ContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?

  init(_ continuation: CheckedContinuation<Void, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Void) {
    take()?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Void, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let value = continuation
    continuation = nil
    return value
  }
}
