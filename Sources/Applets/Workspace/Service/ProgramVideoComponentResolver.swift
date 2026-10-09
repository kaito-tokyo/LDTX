// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel

public enum ProgramVideoComponentResolver {
  public static let coordinateWidth: Float = 1_920
  public static let coordinateHeight: Float = 1_080

  public static func applying(
    _ videoComponents: [ProgramVideoComponentRecord],
    layers: [VideoLayerPreference],
    to composite: CompositeProgramDefinition,
    coordinateWidth: Float = coordinateWidth,
    coordinateHeight: Float = coordinateHeight
  ) -> CompositeProgramDefinition {
    let existingByName = firstProgramStepsByName(composite.steps)
    let componentsByName = firstVideoComponentsByName(videoComponents)
    var resolved = composite
    resolved.steps = layers.compactMap { layer in
      guard
        var step = existingByName[layer.componentName]
          ?? componentsByName[layer.componentName].map({
            CompositeProgramStep(displayName: layer.componentName, component: $0)
          })
      else { return nil }

      if let definitionComponent = componentsByName[layer.componentName] {
        step.component = definitionComponent
      }
      switch step.component {
      case .inputCameraDevice(var payload):
        payload.destinationX = layer.destinationX
        payload.destinationY = layer.destinationY
        payload.destinationScaleX = layer.destinationScaleX
        payload.destinationScaleY = layer.destinationScaleY
        step.component = .inputCameraDevice(payload)
      case .clock(var payload):
        payload.destinationX = layer.destinationX / coordinateWidth
        payload.destinationY = layer.destinationY / coordinateHeight
        payload.destinationWidth = layer.destinationScaleX
        payload.destinationHeight = layer.destinationScaleY
        step.component = .clock(payload)
      default:
        break
      }
      return step
    }
    return resolved
  }

  public static func applying(
    _ videoComponents: [ProgramVideoComponentRecord],
    to composite: CompositeProgramDefinition
  ) -> CompositeProgramDefinition {
    let componentsByName = firstVideoComponentsByName(videoComponents)
    var resolved = composite
    for index in resolved.steps.indices {
      let programComponent = resolved.steps[index].component
      guard var component = componentsByName[resolved.steps[index].name] else { continue }
      if case .inputCameraDevice(var resourcePayload) = component,
        case .inputCameraDevice(let programPayload) = programComponent
      {
        resourcePayload.destinationX = programPayload.destinationX
        resourcePayload.destinationY = programPayload.destinationY
        resourcePayload.destinationScaleX = programPayload.destinationScaleX
        resourcePayload.destinationScaleY = programPayload.destinationScaleY
        component = .inputCameraDevice(resourcePayload)
      } else if case .clock(var resourcePayload) = component,
        case .clock(let programPayload) = programComponent
      {
        // Clock placement is resolved from Program Preferences into the
        // working composite. Keep it while refreshing Definition style.
        resourcePayload.destinationX = programPayload.destinationX
        resourcePayload.destinationY = programPayload.destinationY
        resourcePayload.destinationWidth = programPayload.destinationWidth
        resourcePayload.destinationHeight = programPayload.destinationHeight
        component = .clock(resourcePayload)
      }
      resolved.steps[index].component = component
    }
    return resolved
  }
}

private func firstProgramStepsByName(
  _ steps: [CompositeProgramStep]
) -> [String: CompositeProgramStep] {
  var stepsByName: [String: CompositeProgramStep] = [:]
  for step in steps where stepsByName[step.name] == nil {
    stepsByName[step.name] = step
  }
  return stepsByName
}

private func firstVideoComponentsByName(
  _ videoComponents: [ProgramVideoComponentRecord]
) -> [String: ProgramComponent] {
  var componentsByName: [String: ProgramComponent] = [:]
  for component in videoComponents where componentsByName[component.name] == nil {
    componentsByName[component.name] = component.component
  }
  return componentsByName
}
