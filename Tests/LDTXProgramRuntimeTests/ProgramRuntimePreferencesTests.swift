// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Testing

@testable import LDTXProgramRuntime

struct ProgramRuntimePreferencesTests {
  @Test func sharedProgramStatePublishesARevisionedRuntimeProjection() throws {
    let state = ProgramRuntimeState()
    let initialRevision = state.opaqueRevisionID
    state.replace(with: runtimeConfiguration(componentName: "First"))

    #expect(state.read { $0?.composite.steps.first?.name } == "First")
    let firstRevision = state.opaqueRevisionID
    #expect(firstRevision == initialRevision + 1)

    state.replace(with: runtimeConfiguration(componentName: "First"))
    #expect(state.opaqueRevisionID == firstRevision)

    state.replace(with: runtimeConfiguration(componentName: "Second"))
    #expect(state.read { $0?.composite.steps.first?.name } == "Second")
    #expect(state.opaqueRevisionID == firstRevision + 1)
  }

  @Test func outputConsumptionDoesNotFreezeOrReplaceTheSharedProgram() throws {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    runtime.updateProgram(runtimeConfiguration(componentName: "Before Output"))
    runtime.beginOutput()
    runtime.updateProgram(runtimeConfiguration(componentName: "During Output"))

    #expect(runtime.programState.read { $0?.composite.steps.first?.name } == "During Output")
    runtime.endOutput()
  }

  @Test func workspacePreferencesStateIsSharedByEveryProgramRuntime() {
    let preferencesState = ProgramPreferencesState()
    let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let first = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      programPreferencesState: preferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
    let second = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      programPreferencesState: preferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )

    first.updateProgramPreferences(
      ProgramPreferences(videoMutedByInputDeviceName: ["Camera": true])
    )

    #expect(first.programPreferencesState === second.programPreferencesState)
    #expect(second.programPreferencesState.read { $0.isVideoMuted(inputDeviceName: "Camera") })
  }

  @Test func muteUpdatesDoNotRebuildTheVideoInputPipeline() throws {
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    let initialPipelineID = try #require(renderer.videoPipelineIDForTesting)

    renderer.updateProgramPreferences(
      ProgramPreferences(videoMutedByInputDeviceName: ["Camera": true])
    )
    #expect(renderer.videoPipelineIDForTesting == initialPipelineID)

    renderer.updateProgramPreferences(
      ProgramPreferences(videoMutedByInputDeviceName: ["Camera": false])
    )
    #expect(renderer.videoPipelineIDForTesting == initialPipelineID)
  }

  @Test func videoLayerMutesRetainCameraInputsAndRemoveOtherComponents() {
    let composite = CompositeProgramDefinition(steps: [
      CompositeProgramStep(id: "Camera", component: .inputCameraDevice(InputDeviceComponent())),
      CompositeProgramStep(id: "Solid", component: .fillSolidColor(FillSolidColorComponent())),
      CompositeProgramStep(
        id: "Linear", component: .fillLinearGradient(FillLinearGradientComponent())),
      CompositeProgramStep(
        id: "Radial", component: .fillRadialGradient(FillRadialGradientComponent())),
      CompositeProgramStep(
        id: "Conic", component: .fillConicGradient(FillConicGradientComponent())),
      CompositeProgramStep(id: "Clock", component: .clock(ClockComponent())),
      CompositeProgramStep(id: "Pattern", component: .testPattern),
    ])
    let mutedLayers = composite.steps.map {
      VideoLayerPreference(componentName: $0.name, isMuted: true)
    }
    let preferences = ProgramPreferences(videoLayersByProgramName: [
      "Main": mutedLayers,
      "Other": [VideoLayerPreference(componentName: "Camera", isMuted: false)],
    ])

    let main = compositeApplyingVideoLayerMutes(
      composite,
      preferences: preferences,
      programName: "Main"
    )
    let other = compositeApplyingVideoLayerMutes(
      composite,
      preferences: preferences,
      programName: "Other"
    )

    #expect(main.steps.map { $0.name } == ["Camera"])
    #expect(other.steps == composite.steps)
  }

  @Test func destinationUpdatesDoNotReplaceTheInputPipelineState() {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    let initial = runtimeConfiguration(componentName: "Camera", destinationX: 0)
    runtime.updateProgram(initial)
    let pipelineRevision = runtime.programState.opaqueRevisionID
    let destinationRevision = runtime.programDestinationState.opaqueRevisionID

    runtime.updateProgram(runtimeConfiguration(componentName: "Camera", destinationX: 120))

    #expect(runtime.programState.opaqueRevisionID == pipelineRevision)
    #expect(runtime.programDestinationState.opaqueRevisionID == destinationRevision + 1)
    #expect(runtime.programDestinationState.destination(forStepNamed: "Camera")?.x == 120)
  }

  @Test func duplicateDestinationStepNamesUseTheFirstDestination() {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    var configuration = runtimeConfiguration(componentName: "Camera", destinationX: 120)
    configuration.composite.steps.append(
      CompositeProgramStep(
        id: "Camera",
        component: .inputCameraDevice(InputDeviceComponent(destinationX: 240))
      )
    )

    runtime.updateProgram(configuration)

    #expect(runtime.programDestinationState.destination(forStepNamed: "Camera")?.x == 120)
    #expect(runtime.programState.read { $0?.composite.steps.count } == 1)
  }

  private func runtimeConfiguration(
    componentName: String,
    destinationX: Float = 0
  ) -> ProgramRuntimeConfiguration {
    ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(
          id: componentName,
          component: .inputCameraDevice(
            InputDeviceComponent(destinationX: destinationX)
          )
        )
      ]),
      audioChannels: [],
      canvasWidth: 320,
      canvasHeight: 180,
      outputWidth: 320,
      outputHeight: 180,
      frameRate: 60,
      timeSeconds: 0,
      videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: []
    )
  }
}
