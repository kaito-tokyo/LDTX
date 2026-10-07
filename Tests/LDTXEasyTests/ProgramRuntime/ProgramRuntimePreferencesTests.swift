// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
@testable import LDTXProgramRuntime
import Testing

@Suite
struct ProgramRuntimePreferencesUnitTestSuite {
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

  @Test func sharedProgramStatePreservesRuntimeValuesWithoutSerialization() throws {
    var configuration = runtimeConfiguration(componentName: "Clock")
    var clock = ClockComponent(
      destinationX: 0.3, destinationY: 0.4,
      destinationWidth: 0.5, destinationHeight: 0.6,
      showsSeconds: false, uses24HourTime: false
    )
    clock.outlines = [
      ClockTextOutline(thickness: 1, color: "#000000"),
      ClockTextOutline(thickness: 2, color: "#ffffff"),
      ClockTextOutline(thickness: 3, color: "#ff0000"),
    ]
    configuration.composite.steps = [
      CompositeProgramStep(id: "Clock", component: .clock(clock)),
      CompositeProgramStep(id: "Clock", component: .testPattern),
    ]
    configuration.audioChannels = [ProgramAudioChannel(component: .silentAudio)]
    configuration.outputProfile = configuration.outputProfile.withVideoBitRate(12_345_678)
    let state = ProgramRuntimeState(configuration: configuration)
    let stored = try #require(state.read { $0 })
    #expect(stored.composite.steps == [configuration.composite.steps[0]])
    #expect(stored.composite.audioChannels == configuration.audioChannels)
    #expect(stored.audioChannels == configuration.audioChannels)
    #expect(stored.outputProfile == configuration.outputProfile)
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
      ProgramPreferences(videoHiddenByInputDeviceName: ["Camera": true])
    )

    #expect(first.programPreferencesState === second.programPreferencesState)
    #expect(second.programPreferencesState.read { $0.isVideoHidden(inputDeviceName: "Camera") })
  }

  @Test func visibilityUpdatesDoNotRebuildTheVideoInputPipeline() throws {
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    let initialPipelineID = try #require(renderer.videoPipelineIDForTesting)

    renderer.updateProgramPreferences(
      ProgramPreferences(videoHiddenByInputDeviceName: ["Camera": true])
    )
    #expect(renderer.videoPipelineIDForTesting == initialPipelineID)

    renderer.updateProgramPreferences(
      ProgramPreferences(videoHiddenByInputDeviceName: ["Camera": false])
    )
    #expect(renderer.videoPipelineIDForTesting == initialPipelineID)
  }

  @Test func hiddenLayersAreRemovedFromCompositionIncludingCameraInputs() {
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
    let hiddenLayers = composite.steps.map {
      VideoLayerPreference(componentName: $0.name, isHidden: true)
    }
    let preferences = ProgramPreferences(videoLayersByProgramName: [
      "Main": hiddenLayers,
      "Other": [VideoLayerPreference(componentName: "Camera", isHidden: false)],
    ])

    let main = compositeApplyingVideoLayerVisibility(
      composite,
      preferences: preferences,
      programName: "Main"
    )
    let other = compositeApplyingVideoLayerVisibility(
      composite,
      preferences: preferences,
      programName: "Other"
    )

    #expect(main.steps.isEmpty)
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

  @Test func destinationUpdatesApplyClockPlacementWithoutReplacingInputPipelineState() throws {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    var initial = runtimeConfiguration(componentName: "Camera")
    initial.composite.steps = [
      CompositeProgramStep(
        id: "Clock",
        component: .clock(ClockComponent(destinationX: 0.1, destinationY: 0.2))
      )
    ]
    runtime.updateProgram(initial)
    let pipelineRevision = runtime.programState.opaqueRevisionID

    var updated = initial
    updated.composite.steps[0].component = .clock(
      ClockComponent(
        destinationX: 0.3,
        destinationY: 0.4,
        destinationWidth: 0.5,
        destinationHeight: 0.6
      ))
    runtime.updateDestinations(from: updated.composite)

    let applied = runtime.programDestinationState.applying(to: initial.composite)
    let component = try #require(applied.steps.first?.component)
    guard case .clock(let clock) = component else {
      Issue.record("Expected Clock")
      return
    }
    #expect(runtime.programState.opaqueRevisionID == pipelineRevision)
    #expect(clock.destinationX == 0.3)
    #expect(clock.destinationY == 0.4)
    #expect(clock.destinationWidth == 0.5)
    #expect(clock.destinationHeight == 0.6)
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
