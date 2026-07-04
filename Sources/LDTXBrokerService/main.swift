// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAutomation

final class BrokerState: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: BrokerClientSession] = [:]
    private var appSession: BrokerClientSession?

    func insert(_ session: BrokerClientSession) {
        lock.withLock {
            sessions[ObjectIdentifier(session)] = session
        }
    }

    func remove(_ session: BrokerClientSession) {
        lock.withLock {
            sessions.removeValue(forKey: ObjectIdentifier(session))
            if appSession === session {
                appSession = nil
            }
        }
    }

    func registerApp(_ session: BrokerClientSession) {
        lock.withLock {
            appSession = session
        }
    }

    func forwardToApp(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        let session = lock.withLock { appSession }
        guard let session else {
            reply(errorResponse(
                requestData: requestData,
                message: "LDTX app is not registered with the broker."
            ))
            return
        }
        session.forwardToApp(requestData, withReply: reply)
    }

    private func errorResponse(requestData: Data, message: String) -> Data {
        let request = try? JSONRPCCoding.decodeRequest(requestData)
        let response = JSONRPCResponse(id: request?.id, error: .internalError(message))
        return (try? JSONRPCCoding.encode(response)) ?? Data()
    }
}

final class BrokerClientSession: NSObject, LDTXBrokerXPC {
    private let state: BrokerState
    private weak var connection: NSXPCConnection?

    init(state: BrokerState, connection: NSXPCConnection) {
        self.state = state
        self.connection = connection
    }

    func registerApp(withReply reply: @escaping (Data) -> Void) {
        state.registerApp(self)
        let response = JSONRPCResponse(
            id: nil,
            result: .object(["registered": .bool(true)])
        )
        reply((try? JSONRPCCoding.encode(response)) ?? Data())
    }

    func send(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        state.forwardToApp(requestData, withReply: reply)
    }

    func forwardToApp(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            let request = try? JSONRPCCoding.decodeRequest(requestData)
            let response = JSONRPCResponse(
                id: request?.id,
                error: .internalError(error.localizedDescription)
            )
            reply((try? JSONRPCCoding.encode(response)) ?? Data())
        }) as? LDTXAppXPC else {
            let request = try? JSONRPCCoding.decodeRequest(requestData)
            let response = JSONRPCResponse(
                id: request?.id,
                error: .internalError("LDTX app XPC proxy is unavailable.")
            )
            reply((try? JSONRPCCoding.encode(response)) ?? Data())
            return
        }

        proxy.send(requestData, withReply: reply)
    }
}

final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let state: BrokerState

    init(state: BrokerState) {
        self.state = state
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let session = BrokerClientSession(state: state, connection: newConnection)
        state.insert(session)

        newConnection.exportedInterface = LDTXXPC.brokerInterface()
        newConnection.exportedObject = session
        newConnection.remoteObjectInterface = LDTXXPC.appInterface()
        newConnection.invalidationHandler = { [state, weak session] in
            guard let session else {
                return
            }
            state.remove(session)
        }
        newConnection.interruptionHandler = { [state, weak session] in
            guard let session else {
                return
            }
            state.remove(session)
        }
        newConnection.resume()
        return true
    }
}

let state = BrokerState()
let delegate = BrokerListenerDelegate(state: state)
let listener = NSXPCListener(machServiceName: LDTXAutomationService.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
