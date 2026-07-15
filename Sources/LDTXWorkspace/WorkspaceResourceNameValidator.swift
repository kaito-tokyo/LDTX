// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceResourceNameValidator {
    public static func validate(_ workspace: WorkspaceDefinition) throws {
        var seen = Set<String>()
        for name in workspaceResourceNames(in: workspace) {
            guard seen.insert(name).inserted else {
                throw WorkspaceResourceNameValidationError.duplicateName(name)
            }
        }
    }

    public static func isAvailable(
        _ name: String,
        inputDevices: [WorkspaceInputDeviceRecord],
        visions: [WorkspaceVisionDefinition],
        automations: [WorkspaceAutomationDefinition],
        excludingResourceID: String? = nil
    ) -> Bool {
        !resourceNames(
            inputDevices: inputDevices,
            visions: visions,
            automations: automations,
            excludingResourceID: excludingResourceID
        ).contains(name)
    }

    public static func uniqueName(
        base: String,
        inputDevices: [WorkspaceInputDeviceRecord],
        visions: [WorkspaceVisionDefinition],
        automations: [WorkspaceAutomationDefinition]
    ) -> String {
        let existing = resourceNames(
            inputDevices: inputDevices,
            visions: visions,
            automations: automations
        )
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private static func workspaceResourceNames(in workspace: WorkspaceDefinition) -> [String] {
        workspace.inputDevices.map(\.name) + workspace.visions.map(\.name) + workspace.automations.map(\.name)
    }

    private static func resourceNames(
        inputDevices: [WorkspaceInputDeviceRecord],
        visions: [WorkspaceVisionDefinition],
        automations: [WorkspaceAutomationDefinition],
        excludingResourceID: String? = nil
    ) -> Set<String> {
        Set(
            inputDevices.filter { $0.id != excludingResourceID }.map(\.name)
                + visions.filter { $0.id != excludingResourceID }.map(\.name)
                + automations.filter { $0.id != excludingResourceID }.map(\.name)
        )
    }
}

public enum WorkspaceResourceNameValidationError: LocalizedError, Equatable, Sendable {
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateName(name):
            "Workspace resource name \"\(name)\" is used more than once. Input Devices, Visions, and Automations must have unique names."
        }
    }
}
