// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Validates the internal-ID references in one V4 Workspace definition.
public enum WorkspaceV4IntegrityValidator {
  public static func validate(_ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) throws {
    let inputIDs = Set(try definition.inputDevices.map { try inputDeviceID($0) })
    guard inputIDs.count == definition.inputDevices.count else {
      throw WorkspaceV4IntegrityError.duplicateInternalID
    }
    let componentIDs = Set(try definition.videoComponents.map { try videoComponentID($0) })
    guard componentIDs.count == definition.videoComponents.count,
      inputIDs.isDisjoint(with: componentIDs)
    else { throw WorkspaceV4IntegrityError.duplicateInternalID }
    let programIDs = Set(definition.programs.map(\.internalID))
    guard programIDs.count == definition.programs.count else {
      throw WorkspaceV4IntegrityError.duplicateInternalID
    }
    let videoLayerIDs = inputIDs.union(componentIDs)
    for program in definition.programs {
      for id in program.landscapeVideoLayerInternalIds + program.portraitVideoLayerInternalIds {
        guard videoLayerIDs.contains(id) else { throw WorkspaceV4IntegrityError.missingVideoLayer(id) }
      }
    }
    for component in definition.videoComponents {
      guard case .vfxSource(let source)? = component.definition else { continue }
      guard inputIDs.contains(source.inputDeviceInternalID) else {
        throw WorkspaceV4IntegrityError.missingInputDevice(source.inputDeviceInternalID)
      }
    }
  }

  public static func inputDeviceID(_ wrapper: Ldtx_Workspace_V4_InputDeviceWrapper) throws -> UInt64 {
    switch wrapper.definition {
    case .videoDevice(let device): device.internalID
    case .audioDevice(let device): device.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  public static func videoComponentID(_ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper) throws -> UInt64 {
    switch wrapper.definition {
    case .solidColorFill(let component): component.internalID
    case .linearGradientFill(let component): component.internalID
    case .radialGradientFill(let component): component.internalID
    case .conicGradientFill(let component): component.internalID
    case .vfxSource(let component): component.internalID
    case .clock(let component): component.internalID
    case .testPattern(let component): component.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }
}

public enum WorkspaceV4IntegrityError: Error, Equatable, Sendable {
  case missingConcreteDefinition
  case duplicateInternalID
  case missingVideoLayer(UInt64)
  case missingInputDevice(UInt64)
}
