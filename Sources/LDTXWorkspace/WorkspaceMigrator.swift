// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

public enum WorkspaceMigrationError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(UInt32)
}

/// Upgrades persisted Workspace data before it enters the application model.
///
/// Version zero represents every Workspace written before `format_version`
/// was introduced. Callers outside persistence should only observe the latest
/// Definition and Preferences produced by this boundary.
public enum WorkspaceMigrator {
    public static let currentFormatVersion: UInt32 = 1

    struct ProtobufMigrationResult {
        var workspace: Ldtx_Workspace_V1_Workspace
        var sourceFormatVersion: UInt32
        var legacyPhysicalDeviceIDsByInputDeviceID: [String: String]
    }

    static func migrate(_ persisted: Ldtx_Workspace_V1_Workspace) throws -> ProtobufMigrationResult {
        let sourceVersion = persisted.formatVersion
        guard sourceVersion <= currentFormatVersion else {
            throw WorkspaceMigrationError.unsupportedFormatVersion(sourceVersion)
        }

        var workspace = persisted
        var legacyPhysicalDeviceIDs: [String: String] = [:]
        if sourceVersion == 0 {
            migrateLegacyVisionPrompts(in: &workspace)
            migrateLegacyVideoComponents(in: &workspace)
            for inputDevice in workspace.inputDevices
            where !inputDevice.physicalDeviceID.isEmpty
                && legacyPhysicalDeviceIDs[inputDevice.name] == nil
            {
                legacyPhysicalDeviceIDs[inputDevice.name] = inputDevice.physicalDeviceID
            }
        }
        workspace.formatVersion = currentFormatVersion
        return ProtobufMigrationResult(
            workspace: workspace,
            sourceFormatVersion: sourceVersion,
            legacyPhysicalDeviceIDsByInputDeviceID: legacyPhysicalDeviceIDs
        )
    }

    static func migrate(
        definition: WorkspaceDefinition,
        preferences: WorkspacePreferences,
        protobufMigration: ProtobufMigrationResult
    ) -> WorkspaceSnapshot {
        var migratedDefinition = definition
        var migratedPreferences = preferences
        if protobufMigration.sourceFormatVersion == 0 {
            for (inputDeviceID, physicalDeviceID) in
                protobufMigration.legacyPhysicalDeviceIDsByInputDeviceID
            where migratedPreferences.physicalDeviceIDsByInputDeviceID[inputDeviceID] == nil {
                migratedPreferences.physicalDeviceIDsByInputDeviceID[inputDeviceID] = physicalDeviceID
            }
            migrateLegacyVideoLayers(
                definition: &migratedDefinition,
                preferences: &migratedPreferences.programPreferences
            )
            migrateLegacyProgramComponents(in: &migratedDefinition)
        }
        return WorkspaceSnapshot(
            definition: migratedDefinition,
            preferences: migratedPreferences
        )
    }

    static func removeObsoletePackageArtifacts(
        at packageURL: URL,
        fileManager: FileManager
    ) throws {
        let legacyLockURL = packageURL.appendingPathComponent("LDTX.lock")
        if fileManager.fileExists(atPath: legacyLockURL.path) {
            try fileManager.removeItem(at: legacyLockURL)
        }
    }

    private static func migrateLegacyVisionPrompts(
        in workspace: inout Ldtx_Workspace_V1_Workspace
    ) {
        for index in workspace.visions.indices
        where workspace.visions[index].systemPrompt.isEmpty
            && !workspace.visions[index].prompt.isEmpty {
            workspace.visions[index].systemPrompt = workspace.visions[index].prompt
        }
    }

    private static func migrateLegacyVideoComponents(
        in workspace: inout Ldtx_Workspace_V1_Workspace
    ) {
        for index in workspace.videoComponents.indices
        where !workspace.videoComponents[index].hasComponent {
            let legacy = workspace.videoComponents[index]
            var input = Ldtx_Program_V1_InputDeviceComponent()
            if !legacy.inputDeviceID.isEmpty { input.inputDeviceID = legacy.inputDeviceID }
            input.sourceCrop = legacy.sourceCrop
            input.backgroundRemovalEnabled = legacy.removesBackground
            var component = Ldtx_Program_V1_ProgramComponent()
            component.inputDevice = input
            workspace.videoComponents[index].component = component
        }
    }

    private static func migrateLegacyVideoLayers(
        definition: inout WorkspaceDefinition,
        preferences: inout ProgramPreferences
    ) {
        // Before Video Layers, a Program could contain a component directly,
        // without a corresponding Workspace Video Component. Video Layers now
        // reference Workspace Video Components exclusively, so promote each
        // such legacy step before recording its placement preference.
        let resourceNames = Set(definition.videoComponents.map(\.name))
        var usedNames = Set(
            definition.inputDevices.map(\.name)
                + definition.videoComponents.map(\.name)
                + definition.visions.map(\.name)
        )
        for programIndex in definition.programs.indices
        where preferences.videoLayersByProgramName[definition.programs[programIndex].name] == nil {
            let programName = definition.programs[programIndex].name
            for stepIndex in definition.programs[programIndex].composite.steps.indices {
                var step = definition.programs[programIndex].composite.steps[stepIndex]
                guard !resourceNames.contains(step.name) else { continue }

                let resourceName = uniqueResourceName(step.name, usedNames: &usedNames)
                step.displayName = resourceName
                definition.programs[programIndex].composite.steps[stepIndex] = step
                definition.videoComponents.append(
                    WorkspaceVideoComponentRecord(name: resourceName, component: step.component)
                )
            }
            let layers = definition.programs[programIndex].composite.steps.map { step -> VideoLayerPreference in
                switch step.component {
                case .inputCameraDevice(let component):
                    return VideoLayerPreference(
                        componentName: step.name,
                        destinationX: component.destinationX,
                        destinationY: component.destinationY,
                        destinationScale: component.destinationScale
                    )
                case .clock(let component):
                    return VideoLayerPreference(
                        componentName: step.name,
                        destinationX: component.destinationX
                            * WorkspaceVideoComponentResolver.coordinateWidth,
                        destinationY: component.destinationY
                            * WorkspaceVideoComponentResolver.coordinateHeight,
                        destinationScale: component.destinationWidth / ClockComponent().destinationWidth
                    )
                default:
                    return VideoLayerPreference(componentName: step.name)
                }
            }
            preferences.setVideoLayers(layers, forProgramNamed: programName)
        }
    }

    private static func uniqueResourceName(_ base: String, usedNames: inout Set<String>) -> String {
        let normalizedBase = base.isEmpty ? "Video Component" : base
        if usedNames.insert(normalizedBase).inserted {
            return normalizedBase
        }
        var suffix = 2
        while true {
            let candidate = "\(normalizedBase) \(suffix)"
            if usedNames.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    private static func migrateLegacyProgramComponents(
        in definition: inout WorkspaceDefinition
    ) {
        for programIndex in definition.programs.indices {
            for stepIndex in definition.programs[programIndex].composite.steps.indices {
                var step = definition.programs[programIndex].composite.steps[stepIndex]
                step.component = migratedDefinitionComponent(step.component)
                definition.programs[programIndex].composite.steps[stepIndex] = step
            }
        }
        for componentIndex in definition.videoComponents.indices {
            definition.videoComponents[componentIndex].component = migratedDefinitionComponent(
                definition.videoComponents[componentIndex].component
            )
        }
    }

    private static func migratedDefinitionComponent(_ component: ProgramComponent) -> ProgramComponent {
        switch component {
        case .inputCameraDevice(var payload):
            payload.destinationX = 0
            payload.destinationY = 0
            payload.destinationScale = 1
            return .inputCameraDevice(payload)
        case .clock(var payload):
            if payload.background.isEmpty {
                payload.background = cssColor(
                    red: payload.backgroundRed,
                    green: payload.backgroundGreen,
                    blue: payload.backgroundBlue,
                    alpha: payload.backgroundAlpha
                )
            }
            payload.destinationX = 0
            payload.destinationY = 0
            payload.destinationWidth = 1
            payload.destinationHeight = 1
            return .clock(payload)
        default:
            return component
        }
    }

    private static func cssColor(red: Float, green: Float, blue: Float, alpha: Float) -> String {
        let normalized = [red, green, blue, alpha].map { value in
            value.isFinite ? min(max(value, 0), 1) : 0
        }
        return String(
            format: "rgba(%d, %d, %d, %.6g)",
            Int((normalized[0] * 255).rounded()),
            Int((normalized[1] * 255).rounded()),
            Int((normalized[2] * 255).rounded()),
            normalized[3]
        )
    }
}
