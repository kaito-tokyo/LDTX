// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAutomation
import OSLog

private let ldtxAutomationLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "Automation"
)

final class LDTXAppAutomationEndpoint: @unchecked Sendable {
    private static let initialReconnectDelay: TimeInterval = 1
    private static let maximumReconnectDelay: TimeInterval = 60

    private var isStarted = false
    private var connection: NSXPCConnection?
    private var appService: LDTXAppXPCService?
    private var reconnectDelay = initialReconnectDelay
    private var isReconnectScheduled = false

    func start(state: AppAutomationState) {
        guard !isStarted else {
            return
        }
        isStarted = true

        connect(state: state)
    }

    private func connect(state: AppAutomationState) {
        let appService = LDTXAppXPCService(state: state)
        let connection = LDTXXPC.makeBrokerConnection()
        connection.exportedInterface = LDTXXPC.appInterface()
        connection.exportedObject = appService
        connection.invalidationHandler = { [weak self, weak state] in
            DispatchQueue.main.async {
                guard let self, let state else {
                    return
                }
                self.scheduleReconnect(state: state)
            }
        }
        connection.interruptionHandler = { [weak self, weak state] in
            DispatchQueue.main.async {
                guard let self, let state else {
                    return
                }
                self.scheduleReconnect(state: state)
            }
        }
        connection.resume()

        self.appService = appService
        self.connection = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self, weak state] error in
            ldtxAutomationLogger.debug(
                "Automation broker registration failed: \(error.localizedDescription, privacy: .public)"
            )
            DispatchQueue.main.async {
                guard let self, let state else {
                    return
                }
                self.scheduleReconnect(state: state)
            }
        }) as? LDTXBrokerXPC else {
            ldtxAutomationLogger.error("Could not create automation broker XPC proxy")
            scheduleReconnect(state: state)
            return
        }
        proxy.registerApp { _ in
            DispatchQueue.main.async { [weak self] in
                self?.markConnected()
                ldtxAutomationLogger.info("Registered app automation endpoint with broker")
            }
        }
    }

    private func scheduleReconnect(state: AppAutomationState) {
        guard !isReconnectScheduled else {
            return
        }
        isReconnectScheduled = true
        connection?.invalidate()
        connection = nil
        appService = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maximumReconnectDelay)

        ldtxAutomationLogger.debug(
            "Scheduling automation broker reconnect in \(delay, privacy: .public) seconds"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state else {
                return
            }
            self.isReconnectScheduled = false
            self.connect(state: state)
        }
    }

    private func markConnected() {
        isReconnectScheduled = false
        reconnectDelay = Self.initialReconnectDelay
    }
}

private final class LDTXAppXPCService: NSObject, LDTXAppXPC {
    private let state: AppAutomationState

    init(state: AppAutomationState) {
        self.state = state
    }

    func send(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONRPCCoding.decodeRequest(requestData)
            handle(request, reply: reply)
        } catch let error as JSONRPCError {
            let response = JSONRPCResponse(id: nil, error: error)
            reply((try? JSONRPCCoding.encode(response)) ?? Data())
        } catch {
            let response = JSONRPCResponse(id: nil, error: .internalError(error.localizedDescription))
            reply((try? JSONRPCCoding.encode(response)) ?? Data())
        }
    }

    private func handle(_ request: JSONRPCRequest, reply: @escaping (Data) -> Void) {
        do {
            let replyHandler = XPCReplyHandler(reply)
            switch request.method {
            case LDTXAutomationMethod.appTerminate:
                state.terminate { [requestID = request.id] result in
                    replyHandler.send(Self.encodedCommandResponse(id: requestID, result: result))
                }
            case LDTXAutomationMethod.programSelect:
                let params = try programSelectParams(from: request)
                state.selectProgram(name: params.name, isScratchPad: params.isScratchPad) { [requestID = request.id] result in
                    replyHandler.send(Self.encodedCommandResponse(id: requestID, result: result))
                }
            case LDTXAutomationMethod.recordStart:
                state.startRecording { [requestID = request.id] result in
                    replyHandler.send(Self.encodedCommandResponse(id: requestID, result: result))
                }
            case LDTXAutomationMethod.recordStop:
                state.stopRecording { [requestID = request.id] result in
                    replyHandler.send(Self.encodedCommandResponse(id: requestID, result: result))
                }
            case LDTXAutomationMethod.selectedProgramName:
                reply(try Self.encodedResponse(selectedProgramNameResponse(for: request)))
            case LDTXAutomationMethod.outputSettingsGet:
                state.outputSettings { [requestID = request.id] settings in
                    replyHandler.send(Self.encodedOutputSettingsResponse(id: requestID, settings: settings))
                }
            case LDTXAutomationMethod.outputSettingsSet:
                let settings = try outputSettingsParams(from: request)
                state.setOutputSettings(settings) { [requestID = request.id] result in
                    replyHandler.send(Self.encodedCommandResponse(id: requestID, result: result))
                }
            default:
                reply(try Self.encodedResponse(JSONRPCResponse(
                    id: request.id,
                    error: .methodNotFound(request.method)
                )))
            }
        } catch let error as JSONRPCError {
            reply(Self.encodedError(id: request.id, error: error))
        } catch {
            reply(Self.encodedError(id: request.id, error: .internalError(error.localizedDescription)))
        }
    }

    private func selectedProgramNameResponse(for request: JSONRPCRequest) throws -> JSONRPCResponse {
        let snapshot = state.selectedProgramNameSnapshot()
        var result = Ldtx_Automation_V1_SelectedProgramNameResult()
        result.name = snapshot.name
        result.isScratchPad = snapshot.isScratchPad
        return try JSONRPCResponse(id: request.id, result: result.jsonRPCValue())
    }

    private func programSelectParams(from request: JSONRPCRequest) throws -> Ldtx_Automation_V1_ProgramSelectParams {
        guard let params = request.params else {
            throw JSONRPCError.invalidParams("Missing program select params.")
        }
        let decoded = try Ldtx_Automation_V1_ProgramSelectParams(jsonRPCValue: params)
        guard decoded.isScratchPad || !decoded.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCError.invalidParams("Program name must not be empty.")
        }
        return decoded
    }

    private func outputSettingsParams(from request: JSONRPCRequest) throws -> Ldtx_Automation_V1_OutputSettings {
        guard let params = request.params else {
            throw JSONRPCError.invalidParams("Missing output settings params.")
        }
        return try Ldtx_Automation_V1_OutputSettings(jsonRPCValue: params)
    }

    private static func encodedCommandResponse(id: JSONRPCID?, result: AppAutomationCommandResult) -> Data {
        var proto = Ldtx_Automation_V1_CommandResult()
        proto.ok = result.ok
        proto.message = result.message
        do {
            return try encodedResponse(JSONRPCResponse(id: id, result: proto.jsonRPCValue()))
        } catch {
            return encodedError(id: id, error: .internalError(error.localizedDescription))
        }
    }

    private static func encodedOutputSettingsResponse(
        id: JSONRPCID?,
        settings: Ldtx_Automation_V1_OutputSettings
    ) -> Data {
        do {
            return try encodedResponse(JSONRPCResponse(id: id, result: settings.jsonRPCValue()))
        } catch {
            return encodedError(id: id, error: .internalError(error.localizedDescription))
        }
    }

    private static func encodedResponse(_ response: JSONRPCResponse) throws -> Data {
        try JSONRPCCoding.encode(response)
    }

    private static func encodedError(id: JSONRPCID?, error: JSONRPCError) -> Data {
        let response = JSONRPCResponse(id: id, error: error)
        return (try? JSONRPCCoding.encode(response)) ?? Data()
    }
}

private final class XPCReplyHandler: @unchecked Sendable {
    private let reply: (Data) -> Void

    init(_ reply: @escaping (Data) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data) {
        reply(data)
    }
}
