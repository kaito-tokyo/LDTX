// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

@objc public protocol LDTXBrokerXPC {
    func registerApp(withReply reply: @escaping (Data) -> Void)
    func send(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol LDTXAppXPC {
    func send(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}

public enum LDTXXPC {
    public static func brokerInterface() -> NSXPCInterface {
        NSXPCInterface(with: LDTXBrokerXPC.self)
    }

    public static func appInterface() -> NSXPCInterface {
        NSXPCInterface(with: LDTXAppXPC.self)
    }

    public static func makeBrokerConnection(
        service: LDTXAutomationServiceIdentity = LDTXAutomationService.full
    ) -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: service.machServiceName,
            options: []
        )
        connection.remoteObjectInterface = brokerInterface()
        return connection
    }
}

public enum LDTXBrokerClient {
    public static func send(
        _ request: JSONRPCRequest,
        service: LDTXAutomationServiceIdentity = LDTXAutomationService.full,
        timeout: TimeInterval = 10
    ) throws -> JSONRPCResponse {
        let connection = LDTXXPC.makeBrokerConnection(service: service)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response: Result<Data, Error>?

        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            lock.withLock {
                response = .failure(error)
            }
            semaphore.signal()
        }) as? LDTXBrokerXPC else {
            connection.invalidate()
            throw JSONRPCError.internalError("Could not create Broker XPC proxy.")
        }

        let requestData = try JSONRPCCoding.encode(request)
        proxy.send(requestData) { responseData in
            lock.withLock {
                response = .success(responseData)
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            connection.invalidate()
            throw JSONRPCError.internalError("Broker XPC request timed out.")
        }

        let result = lock.withLock { response }
        connection.invalidate()

        switch result {
        case let .success(data):
            return try JSONRPCCoding.decodeResponse(data)
        case let .failure(error):
            throw error
        case .none:
            throw JSONRPCError.internalError("Broker XPC request did not produce a response.")
        }
    }
}
