// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXWorkspace

extension CompositeProgramDefinition {
  func resolvedVideoComponentDisplayName(
    for step: CompositeProgramStep,
    workspaceInputDevices: [WorkspaceInputDeviceRecord]
  ) -> String {
    resolvedVideoComponentDisplayNames(workspaceInputDevices: workspaceInputDevices)[step.id]
      ?? videoComponentBaseDisplayName(for: step, workspaceInputDevices: workspaceInputDevices)
  }

  func resolvedVideoComponentDisplayNames(
    workspaceInputDevices: [WorkspaceInputDeviceRecord]
  ) -> [String: String] {
    var occurrences: [String: Int] = [:]
    var result: [String: String] = [:]

    for step in steps {
      let baseName = videoComponentBaseDisplayName(
        for: step,
        workspaceInputDevices: workspaceInputDevices
      )
      let occurrence = occurrences[baseName, default: 0] + 1
      occurrences[baseName] = occurrence
      result[step.id] = occurrence == 1 ? baseName : "\(baseName) \(occurrence)"
    }

    return result
  }

  func uniqueVideoComponentDisplayName(
    from proposedName: String,
    excluding excludedStepID: String?,
    workspaceInputDevices: [WorkspaceInputDeviceRecord]
  ) -> String {
    let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      return trimmedName
    }

    let usedNames: Set<String> = Set(
      steps.compactMap { step in
        guard step.id != excludedStepID else {
          return nil
        }
        return resolvedVideoComponentDisplayName(
          for: step,
          workspaceInputDevices: workspaceInputDevices
        )
      }
    )

    guard usedNames.contains(trimmedName) else {
      return trimmedName
    }

    var suffix = 2
    while usedNames.contains("\(trimmedName) \(suffix)") {
      suffix += 1
    }
    return "\(trimmedName) \(suffix)"
  }

  private func videoComponentBaseDisplayName(
    for step: CompositeProgramStep,
    workspaceInputDevices: [WorkspaceInputDeviceRecord]
  ) -> String {
    if let displayName = step.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !displayName.isEmpty
    {
      return displayName
    }

    if case .inputCameraDevice(let component) = step.component,
      let inputDeviceID = component.inputDeviceID,
      let inputDevice = workspaceInputDevices.first(where: { $0.id == inputDeviceID })
    {
      let deviceName = inputDevice.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !deviceName.isEmpty {
        return deviceName
      }
    }

    return videoComponentDisplayName(for: step)
  }
}
