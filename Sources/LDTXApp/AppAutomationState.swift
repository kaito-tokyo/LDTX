// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation
import LDTXAutomation

struct AppAutomationCommandResult: Sendable {
    var ok: Bool
    var message: String
}

struct AppAutomationHandlers: Sendable {
    var terminate: @MainActor @Sendable () -> AppAutomationCommandResult
    var selectProgram: @MainActor @Sendable (_ name: String, _ isScratchPad: Bool) -> AppAutomationCommandResult
    var startRecording: @MainActor @Sendable () -> AppAutomationCommandResult
    var stopRecording: @MainActor @Sendable () -> AppAutomationCommandResult
    var outputSettings: @MainActor @Sendable () -> Ldtx_Automation_V1_OutputSettings
    var setOutputSettings: @MainActor @Sendable (_ settings: Ldtx_Automation_V1_OutputSettings) -> AppAutomationCommandResult
}

final class AppAutomationState: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var selectedProgramName = ""
    private var selectedProgramIsScratchPad = false
    private var handlers: AppAutomationHandlers?

    func updateSelectedProgram(name: String, isScratchPad: Bool) {
        lock.withLock {
            selectedProgramName = name
            selectedProgramIsScratchPad = isScratchPad
        }
    }

    func updateHandlers(_ handlers: AppAutomationHandlers) {
        lock.withLock {
            self.handlers = handlers
        }
    }

    func selectedProgramNameSnapshot() -> (name: String, isScratchPad: Bool) {
        lock.withLock {
            (selectedProgramName, selectedProgramIsScratchPad)
        }
    }

    func terminate(completion: @escaping @Sendable (AppAutomationCommandResult) -> Void) {
        guard let handlers = automationHandlers() else {
            completion(.failure("Automation handlers are not ready."))
            return
        }

        Task { @MainActor in
            completion(handlers.terminate())
        }
    }

    func selectProgram(
        name: String,
        isScratchPad: Bool,
        completion: @escaping @Sendable (AppAutomationCommandResult) -> Void
    ) {
        guard let handlers = automationHandlers() else {
            completion(.failure("Automation handlers are not ready."))
            return
        }

        Task { @MainActor in
            completion(handlers.selectProgram(name, isScratchPad))
        }
    }

    func startRecording(completion: @escaping @Sendable (AppAutomationCommandResult) -> Void) {
        guard let handlers = automationHandlers() else {
            completion(.failure("Automation handlers are not ready."))
            return
        }

        Task { @MainActor in
            completion(handlers.startRecording())
        }
    }

    func stopRecording(completion: @escaping @Sendable (AppAutomationCommandResult) -> Void) {
        guard let handlers = automationHandlers() else {
            completion(.failure("Automation handlers are not ready."))
            return
        }

        Task { @MainActor in
            completion(handlers.stopRecording())
        }
    }

    func outputSettings(completion: @escaping @Sendable (Ldtx_Automation_V1_OutputSettings) -> Void) {
        guard let handlers = automationHandlers() else {
            completion(Ldtx_Automation_V1_OutputSettings())
            return
        }

        Task { @MainActor in
            completion(handlers.outputSettings())
        }
    }

    func setOutputSettings(
        _ settings: Ldtx_Automation_V1_OutputSettings,
        completion: @escaping @Sendable (AppAutomationCommandResult) -> Void
    ) {
        guard let handlers = automationHandlers() else {
            completion(.failure("Automation handlers are not ready."))
            return
        }

        Task { @MainActor in
            completion(handlers.setOutputSettings(settings))
        }
    }

    private func automationHandlers() -> AppAutomationHandlers? {
        lock.withLock {
            handlers
        }
    }
}

private extension AppAutomationCommandResult {
    static func failure(_ message: String) -> AppAutomationCommandResult {
        AppAutomationCommandResult(ok: false, message: message)
    }
}
