// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXWorkspace
import SwiftProtobuf
import Testing

struct WorkspacePersistenceCodecTests {
  @Test func encodedWorkspaceDeclaresCurrentFormatVersion() throws {
    let data = try WorkspacePersistenceCodec.encodeWorkspace(WorkspaceDefinition())
    let proto = try Ldtx_Workspace_V3_Workspace(serializedBytes: data)

    #expect(proto.formatVersion == WorkspacePersistenceCodec.formatVersion)
    #expect(WorkspacePersistenceCodec.formatVersion == 3)
  }

  @Test func workspaceLineageIDRoundTripsAsBackupReferenceInformation() throws {
    let lineageID = UUID()
    let workspace = WorkspaceDefinition(lineageID: lineageID)

    let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
    let proto = try Ldtx_Workspace_V3_Workspace(serializedBytes: data)
    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

    #expect(proto.lineageID == lineageID.uuidString.lowercased())
    #expect(decoded.definition.lineageID == lineageID)
  }

  @Test func decodingRejectsInvalidWorkspaceLineageID() throws {
    let data = try WorkspacePersistenceCodec.encodeWorkspace(WorkspaceDefinition())
    var proto = try Ldtx_Workspace_V3_Workspace(serializedBytes: data)
    proto.lineageID = "not-a-uuid"

    #expect(throws: (any Error).self) {
      try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
    }
  }

  @Test func supportedProfilesPersistTheirStableIdentifiers() throws {
    let data = try WorkspacePersistenceCodec.encodeWorkspace(WorkspaceDefinition())
    let proto = try Ldtx_Workspace_V3_Workspace(serializedBytes: data)

    #expect(
      proto.outputConfiguration.landscapeProfileID
        == WorkspaceOutputProfileID.sdrLandscape1080p60.rawValue)
    #expect(
      proto.outputConfiguration.portraitProfileID
        == WorkspaceOutputProfileID.sdrPortrait1080p60.rawValue)
  }

  @Test func decodingRejectsCanvasWithoutNestedProgram() throws {
    let workspace = WorkspaceDefinition(
      programs: [
        SavedProgramDefinitionRecord(
          name: "Program",
          canvasWidth: 1_920,
          canvasHeight: 1_080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition())
      ])
    let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
    var proto = try Ldtx_Workspace_V3_Workspace(serializedBytes: data)
    var program = try #require(proto.programs.first)
    program.landscape.clearProgram()
    proto.programs[0] = program

    #expect(throws: (any Error).self) {
      try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
    }
  }

  @Test(arguments: [UInt32(0), 1, 2, 4])
  func decodingRejectsEveryNonV3WorkspaceFormatVersion(_ version: UInt32) throws {
    var proto = Ldtx_Workspace_V3_Workspace()
    proto.formatVersion = version

    #expect(throws: WorkspacePersistenceError.unsupportedLegacyFormat(version)) {
      try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
    }
  }

  @Test func workspaceRoundTripsThroughProtobufPersistence() throws {
    let videoStep = CompositeProgramStep(
      displayName: "Camera Component",
      component: .inputCameraDevice(
        InputDeviceComponent(
          inputDeviceID: "Game Capture",
          sourceCropTop: 10,
          removesBackground: true
        ))
    )
    let audioChannel = ProgramAudioChannel(
      component: .inputAudioDevice(InputAudioDeviceComponent())
    )
    let composite = CompositeProgramDefinition(
      steps: [videoStep],
      audioChannels: [audioChannel]
    )

    let workspace = WorkspaceDefinition(
      name: "Streaming Setup",
      programs: [
        SavedProgramDefinitionRecord(
          name: "Switch 2",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: composite
        )
      ],
      inputDevices: [
        WorkspaceInputDeviceRecord(
          id: "Game Capture",
          name: "Game Capture",
          kind: .video,
          captureWidthOverride: 1280,
          captureHeightOverride: 720,
          captureFrameRateOverride: 30
        ),
        WorkspaceInputDeviceRecord(
          id: "Game Audio",
          name: "Game Audio",
          kind: .audio,
        ),
        WorkspaceInputDeviceRecord(
          id: "Mic",
          name: "Mic",
          kind: .audio
        ),
      ],
      audioChannels: [audioChannel],
      visions: [
        WorkspaceVisionDefinition(
          id: "Scene Analyzer",
          name: "Scene Analyzer",
          source: .inputDevice(name: "Game Capture"),
          sourceCrop: .init(top: 10, right: 5, bottom: 15, left: 20),
          model: .qwen3VL2BInstruct4Bit,
          systemPrompt: "Return a concise scene description.",
          userPrompt: "Describe this frame.",
          updateIntervalSeconds: 2,
          stopsAtNewline: true
        )
      ],
      videoComponents: [
        WorkspaceVideoComponentRecord(
          name: "Camera Component",
          inputDeviceID: "Game Capture",
          sourceCropTop: 10,
          removesBackground: true
        ),
        WorkspaceVideoComponentRecord(
          name: "Background",
          component: .fillSolidColor(FillSolidColorComponent(red: 0.1, green: 0.2, blue: 0.3))
        ),
        WorkspaceVideoComponentRecord(
          name: "Local Clock",
          component: .clock(
            ClockComponent(
              showsSeconds: false,
              uses24HourTime: true,
              foregroundRed: 0.9,
              foregroundGreen: 0.8,
              foregroundBlue: 0.7,
              backgroundRed: 0.1,
              backgroundGreen: 0.2,
              backgroundBlue: 0.3,
              backgroundAlpha: 0.5
            ))
        ),
      ],
      outputConfiguration: WorkspaceOutputConfiguration(
        profileID: .sdrLandscape1080p60,
        canvasWidth: 1920,
        canvasHeight: 1080,
        frameRate: 60,
        videoBitRate: 9_000_000,
        videoPTSMasterInputDeviceID: "Game Capture"
      )
    )

    var programPreferences = ProgramPreferences()
    programPreferences.setVideoLayers(
      [VideoLayerPreference(componentName: videoStep.name)],
      forProgramNamed: "Switch 2"
    )
    let preferences = WorkspacePreferences(programPreferences: programPreferences)
    let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: data,
      preferences: preferences
    )

    #expect(decoded.definition == workspace)
    #expect(decoded.preferences == preferences)
  }

  @Test func customVisionModelDigestsRoundTripThroughProtobufPersistence() throws {
    let model = WorkspaceVisionModel(
      repositoryID: "example/custom-model",
      revision: "revision-1",
      expectedWeightSHA256: [
        "model-00001-of-00002.safetensors": String(repeating: "a", count: 64),
        "model-00002-of-00002.safetensors": String(repeating: "b", count: 64),
      ])
    let workspace = WorkspaceDefinition(
      visions: [WorkspaceVisionDefinition(name: "Custom", model: model)])

    let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

    #expect(decoded.definition.visions.first?.model == model)
  }

  @Test func legacyVisionModelJSONDefaultsToNoExpectedDigests() throws {
    let data = Data(#"{"repositoryID":"example/legacy","revision":"main"}"#.utf8)

    let model = try JSONDecoder().decode(WorkspaceVisionModel.self, from: data)

    #expect(model.repositoryID == "example/legacy")
    #expect(model.revision == "main")
    #expect(model.expectedWeightSHA256.isEmpty)
  }

  @Test func legacyBuiltInRepositoryPreservesExplicitCustomRevision() throws {
    let model = WorkspaceVisionModel(
      repositoryID: WorkspaceVisionModel.qwen3VL2BInstruct4Bit.repositoryID,
      revision: "custom-revision"
    )
    let data = try WorkspacePersistenceCodec.encodeWorkspace(
      WorkspaceDefinition(visions: [WorkspaceVisionDefinition(model: model)]))

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

    #expect(decoded.definition.visions.first?.model == model)
  }

  @Test func visionModelCacheIdentityIncludesStableExpectedDigests() {
    let digestA = String(repeating: "a", count: 64)
    let digestB = String(repeating: "b", count: 64)
    let first = WorkspaceVisionModel(
      repositoryID: "example/model", revision: "revision",
      expectedWeightSHA256: ["b.safetensors": digestB, "a.safetensors": digestA])
    let reordered = WorkspaceVisionModel(
      repositoryID: "example/model", revision: "revision",
      expectedWeightSHA256: ["a.safetensors": digestA, "b.safetensors": digestB])
    let changed = WorkspaceVisionModel(
      repositoryID: "example/model", revision: "revision",
      expectedWeightSHA256: ["a.safetensors": digestB, "b.safetensors": digestB])

    #expect(first.cacheKey == reordered.cacheKey)
    #expect(first.cacheKey != changed.cacheKey)
  }

  @Test func visionOCRDefinitionRoundTrips() throws {
    var vision = WorkspaceVisionDefinition(
      name: "Score OCR",
      source: .landscapeProgramOutput,
      sourceCrop: .init(top: 5, right: 10, bottom: 60, left: 10),
      updateIntervalSeconds: 0.5
    )
    vision.definition = .opticalCharacterRecognition(
      .init(
        recognitionLevel: .fast,
        recognitionLanguages: ["ja-JP", "en-US"],
        usesLanguageCorrection: false,
        subsamplingRate: 4
      ))
    let workspace = WorkspaceDefinition(visions: [vision])

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
    )

    #expect(decoded.definition == workspace)
  }

  @Test func visionHistogramGateRoundTripsForVLMAndOCR() throws {
    var vlm = WorkspaceVisionDefinition(
      name: "Gated VLM",
      histogramGate: .init(
        channel: .hue,
        binCount: 15,
        expectedPeakBin: 8,
        minimumPeakRatio: 0.5,
        region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
      )
    )
    var ocr = WorkspaceVisionDefinition(name: "Gated OCR")
    ocr.definition = .opticalCharacterRecognition(.init())
    ocr.histogramGate = .init(
      channel: .value,
      binCount: 8,
      expectedPeakBin: 0,
      minimumPeakRatio: 0.8
    )
    let workspace = WorkspaceDefinition(visions: [vlm, ocr])

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
    )

    #expect(decoded.definition == workspace)
    vlm.histogramGate = nil
    let ungated = WorkspaceDefinition(visions: [vlm])
    #expect(
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(ungated)
      ).definition == ungated
    )
  }

  @Test func visionHistogramGateNormalizesMutableIntegerValuesWhenSaving() throws {
    var gate = WorkspaceVisionHistogramGate()
    gate.binCount = Int.max
    gate.expectedPeakBin = Int.max
    var vision = WorkspaceVisionDefinition(name: "Invalid histogram integers")
    vision.histogramGate = gate

    let decodedMaximums = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(.init(visions: [vision]))
    )
    let maximumGate = try #require(decodedMaximums.definition.visions.first?.histogramGate)
    #expect(maximumGate.binCount == 256)
    #expect(maximumGate.expectedPeakBin == 255)

    gate.binCount = -1
    gate.expectedPeakBin = -1
    vision.histogramGate = gate
    let decodedMinimums = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(.init(visions: [vision]))
    )
    let minimumGate = try #require(decodedMinimums.definition.visions.first?.histogramGate)
    #expect(minimumGate.binCount == 1)
    #expect(minimumGate.expectedPeakBin == 0)
  }

  @Test func visionHistogramGateUsesDefaultsOnlyForOmittedScalars() throws {
    var omittedVision = Ldtx_Workspace_V3_VisionRecord()
    omittedVision.name = "Omitted histogram scalars"
    omittedVision.histogramGate = .init()
    var explicitZeroVision = Ldtx_Workspace_V3_VisionRecord()
    explicitZeroVision.name = "Explicit zero histogram scalars"
    explicitZeroVision.histogramGate.minimumPeakRatio = 0
    explicitZeroVision.histogramGate.binCount = 0
    var workspace = Ldtx_Workspace_V3_Workspace()
    workspace.formatVersion = WorkspacePersistenceCodec.formatVersion
    workspace.lineageID = UUID().uuidString
    workspace.outputConfiguration = validOutputConfiguration()
    workspace.visions = [omittedVision, explicitZeroVision]

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: workspace.serializedData())
    let omittedGate = try #require(decoded.definition.visions[0].histogramGate)
    #expect(omittedGate.binCount == 8)
    #expect(omittedGate.expectedPeakBin == 0)
    #expect(omittedGate.minimumPeakRatio == 0.8)

    let explicitZeroGate = try #require(decoded.definition.visions[1].histogramGate)
    #expect(explicitZeroGate.binCount == 1)
    #expect(explicitZeroGate.minimumPeakRatio == 0)
  }

  @Test func visionUpdateIntervalsAreAtLeastFiveSeconds() throws {
    #expect(WorkspaceVisionDefinition(updateIntervalSeconds: 0.5).updateIntervalSeconds == 5)
    #expect(WorkspaceVisionDefinition(updateIntervalSeconds: 5).updateIntervalSeconds == 5)
    #expect(WorkspaceVisionDefinition(updateIntervalSeconds: 10).updateIntervalSeconds == 10)
    #expect(WorkspaceVisionDefinition(updateIntervalSeconds: 0).updateIntervalSeconds == nil)
    var edited = WorkspaceVisionDefinition()
    edited.updateIntervalSeconds = 2
    #expect(edited.updateIntervalSeconds == 5)

    var vision = Ldtx_Workspace_V3_VisionRecord()
    vision.name = "Legacy fast Vision"
    vision.updateIntervalSeconds = 1
    var workspace = Ldtx_Workspace_V3_Workspace()
    workspace.formatVersion = WorkspacePersistenceCodec.formatVersion
    workspace.lineageID = UUID().uuidString
    workspace.outputConfiguration = validOutputConfiguration()
    workspace.visions = [vision]

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: workspace.serializedData())
    #expect(decoded.definition.visions.first?.updateIntervalSeconds == 5)
  }

  @Test func nonFiniteVisionHistogramRegionDecodesAsClosed() throws {
    var vision = Ldtx_Workspace_V3_VisionRecord()
    vision.name = "Invalid histogram region"
    vision.histogramGate.channel = .value
    vision.histogramGate.binCount = 8
    vision.histogramGate.minimumPeakRatio = 0.8
    vision.histogramGate.region.x = .nan
    vision.histogramGate.region.width = 1
    vision.histogramGate.region.height = 1
    var workspace = Ldtx_Workspace_V3_Workspace()
    workspace.formatVersion = WorkspacePersistenceCodec.formatVersion
    workspace.lineageID = UUID().uuidString
    workspace.outputConfiguration = validOutputConfiguration()
    workspace.visions = [vision]

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: workspace.serializedData())
    let region = try #require(decoded.definition.visions.first?.histogramGate?.region)
    #expect(region == .init(x: 0, y: 0, width: 0, height: 0))
  }

  @Test func visionOCRUsesDomainDefaultsWhenOptionsAreUnset() throws {
    var vision = Ldtx_Workspace_V3_VisionRecord()
    vision.name = "OCR"
    vision.landscapeProgramOutput = true
    vision.opticalCharacterRecognition = .init()
    var workspace = Ldtx_Workspace_V3_Workspace()
    workspace.formatVersion = WorkspacePersistenceCodec.formatVersion
    workspace.lineageID = UUID().uuidString
    workspace.outputConfiguration = validOutputConfiguration()
    workspace.name = "Workspace"
    workspace.visions = [vision]

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: workspace.serializedData()
    )

    guard
      case .opticalCharacterRecognition(let definition) =
        decoded.definition.visions.first?.definition
    else {
      Issue.record("Expected OCR definition")
      return
    }
    #expect(definition.recognitionLevel == .accurate)
    #expect(definition.recognitionLanguages.isEmpty)
    #expect(definition.usesLanguageCorrection)
    #expect(definition.subsamplingRate == 2)
  }

  @Test func backgroundRemovalCanBeDisabledExplicitly() throws {
    var workspace = WorkspaceDefinition(
      videoComponents: [
        WorkspaceVideoComponentRecord(
          name: "Portrait",
          component: .inputCameraDevice(InputDeviceComponent(removesBackground: true))
        )
      ]
    )

    #expect(workspace.videoComponents[0].removesBackground)

    workspace.videoComponents[0].removesBackground = false
    #expect(!workspace.videoComponents[0].removesBackground)
  }

  @Test func workspaceVideoComponentResolverPreservesOnlyProgramDestination() throws {
    let programStep = CompositeProgramStep(
      displayName: "Portrait",
      component: .inputCameraDevice(
        InputDeviceComponent(
          inputDeviceID: "Old Camera",
          sourceCropTop: 1,
          destinationX: 120,
          destinationY: 80,
          destinationScale: 0.5
        ))
    )
    let resource = WorkspaceVideoComponentRecord(
      name: "Portrait",
      inputDeviceID: "Current Camera",
      sourceCropTop: 25,
      removesBackground: true
    )

    let resolved = WorkspaceVideoComponentResolver.applying(
      [resource],
      to: CompositeProgramDefinition(steps: [programStep])
    )
    let payload = try #require(inputDeviceComponent(in: resolved.steps[0].component))

    #expect(payload.inputDeviceID == "Current Camera")
    #expect(payload.sourceCropTop == 25)
    #expect(payload.removesBackground)
    #expect(payload.destinationX == 120)
    #expect(payload.destinationY == 80)
    #expect(payload.destinationScale == 0.5)
  }

  @Test func videoComponentResolverUsesTheFirstComponentForDuplicateNames() throws {
    let first = WorkspaceVideoComponentRecord(
      name: "Camera",
      inputDeviceID: "First Camera",
      sourceCropTop: 10
    )
    let duplicate = WorkspaceVideoComponentRecord(
      name: "Camera",
      inputDeviceID: "Second Camera",
      sourceCropTop: 25
    )
    let composite = CompositeProgramDefinition(steps: [
      CompositeProgramStep(
        displayName: "Camera",
        component: .inputCameraDevice(InputDeviceComponent())
      )
    ])

    let resolved = WorkspaceVideoComponentResolver.applying([first, duplicate], to: composite)
    let payload = try #require(inputDeviceComponent(in: resolved.steps[0].component))

    #expect(payload.inputDeviceID == "First Camera")
    #expect(payload.sourceCropTop == 10)
  }

  @Test func workspaceClockResolverPreservesResolvedLayerPlacement() throws {
    let programStep = CompositeProgramStep(
      displayName: "Clock",
      component: .clock(
        ClockComponent(
          destinationX: 0.2,
          destinationY: 0.3,
          destinationWidth: 0.4,
          destinationHeight: 0.5
        ))
    )
    let resource = WorkspaceVideoComponentRecord(
      name: "Clock",
      component: .clock(ClockComponent(showsDate: true))
    )
    let resolved = WorkspaceVideoComponentResolver.applying(
      [resource],
      to: CompositeProgramDefinition(steps: [programStep])
    )
    guard case .clock(let clock) = resolved.steps[0].component else {
      Issue.record("Expected Clock")
      return
    }
    #expect(clock.showsDate)
    #expect(clock.destinationX == 0.2)
    #expect(clock.destinationY == 0.3)
    #expect(clock.destinationWidth == 0.4)
    #expect(clock.destinationHeight == 0.5)
  }

  @Test func decodingDiscardsDuplicateProgramStepsAfterTheFirst() throws {
    let firstStep = CompositeProgramStep(
      displayName: "Camera",
      component: .inputCameraDevice(InputDeviceComponent(sourceCropTop: 10))
    )
    let duplicateStep = CompositeProgramStep(
      displayName: "Camera",
      component: .inputCameraDevice(InputDeviceComponent(sourceCropTop: 25))
    )
    let workspace = WorkspaceDefinition(
      programs: [
        SavedProgramDefinitionRecord(
          name: "Main",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition(steps: [firstStep, duplicateStep])
        )
      ],
      videoComponents: [
        WorkspaceVideoComponentRecord(name: "Camera", component: firstStep.component)
      ]
    )

    var programPreferences = ProgramPreferences()
    programPreferences.setVideoLayers(
      [VideoLayerPreference(componentName: firstStep.name)],
      forProgramNamed: "Main"
    )
    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
      preferences: WorkspacePreferences(programPreferences: programPreferences)
    )

    #expect(decoded.definition.programs[0].composite.steps == [firstStep])
  }

  @Test func workspacePreferencesRoundTripSeparatelyFromDefinition() throws {
    let preferences = WorkspacePreferences(
      programPreferences: ProgramPreferences(
        audioChannelGainsByName: ["mic": 0.5],
        videoMutedByInputDeviceName: ["Camera": false]
      ),
      physicalDeviceIDsByInputDeviceID: ["camera": "physical-camera"],
      inputCameraDeviceMappings: ["camera-step": "physical-camera"],
      inputAudioDeviceMappings: ["audio-channel": "physical-audio"],
      inputAudioMonitorChannelKeys: ["audio-channel"],
      selectedProgramName: "Switch 2",
      outputDestination: OutputDestination(
        recordsLocally: true,
        streamsToYouTube: true,
        overridesOutputFolder: true,
        outputFolderPath: "/tmp/output",
        recordingCustomFields: ["event": "final", "note": ""]
      )
    )

    let data = try WorkspacePersistenceCodec.encodePreferences(preferences)

    #expect(try WorkspacePersistenceCodec.decodePreferences(from: data) == preferences)
  }

  @Test func newWorkspacePreferencesPersistAConcreteOutputDestination() throws {
    let preferences = WorkspacePreferences()

    let data = try WorkspacePersistenceCodec.encodePreferences(preferences)
    let proto = try Ldtx_Workspace_V3_WorkspacePreferences(serializedBytes: data)

    #expect(proto.hasOutputDestination)
    #expect(proto.outputDestination.recordsLandscape)
    #expect(!proto.outputDestination.recordsPortrait)
    #expect(!proto.outputDestination.streamsToYoutube)
    #expect(preferences.outputDestination == .newWorkspaceInitialValue)
  }

  @Test func preferencesWithoutV3FormatVersionAreRejected() throws {
    let data = try Ldtx_Workspace_V3_WorkspacePreferences().serializedData()

    #expect(throws: WorkspacePersistenceError.unsupportedLegacyFormat(0)) {
      try WorkspacePersistenceCodec.decodePreferences(from: data)
    }
  }

  @Test func applicationOutputPreferencesRoundTripOutsideWorkspacePackage() throws {
    let preferences = ApplicationOutputPreferences(defaultOutputFolderPath: "/tmp/output")

    let data = try ApplicationOutputPreferencesPersistenceCodec.encode(preferences)

    #expect(try ApplicationOutputPreferencesPersistenceCodec.decode(from: data) == preferences)
  }

  @Test func legacyApplicationOutputFolderMigratesWhenCurrentPreferencesAreAbsent() throws {
    var legacy = Ldtx_App_V1_LegacyOutputSettings()
    legacy.recording.baseDirectoryPath = "/tmp/legacy-output/../recordings"

    let migrated =
      try ApplicationOutputPreferencesPersistenceCodec
      .migrateLegacyOutputSettingsIfNeeded(
        currentData: Data(),
        legacyData: legacy.serializedData()
      )
    let migratedData = try #require(migrated)
    let preferences = try ApplicationOutputPreferencesPersistenceCodec.decode(from: migratedData)

    #expect(preferences.defaultOutputFolderPath == "/tmp/recordings")
  }

  @Test func legacyApplicationOutputFolderDoesNotOverwriteCurrentPreferences() throws {
    let current = try ApplicationOutputPreferencesPersistenceCodec.encode(
      ApplicationOutputPreferences(defaultOutputFolderPath: "/tmp/current")
    )
    var legacy = Ldtx_App_V1_LegacyOutputSettings()
    legacy.recording.baseDirectoryPath = "/tmp/legacy"

    #expect(
      try ApplicationOutputPreferencesPersistenceCodec.migrateLegacyOutputSettingsIfNeeded(
        currentData: current,
        legacyData: legacy.serializedData()
      ) == nil)
  }

  @Test func invalidLegacyApplicationOutputFolderIsIgnored() throws {
    var legacy = Ldtx_App_V1_LegacyOutputSettings()
    legacy.recording.baseDirectoryPath = "relative/output"

    #expect(
      try ApplicationOutputPreferencesPersistenceCodec.migrateLegacyOutputSettingsIfNeeded(
        currentData: Data(),
        legacyData: legacy.serializedData()
      ) == nil)
    #expect(
      try ApplicationOutputPreferencesPersistenceCodec.migrateLegacyOutputSettingsIfNeeded(
        currentData: Data(),
        legacyData: Data()
      ) == nil)
  }

  @Test func appPreviewSettingsRoundTripOutsideWorkspacePackage() throws {
    let settings = AppPreviewSettings(prefersColor: true)

    let data = try AppPreviewSettingsPersistenceCodec.encode(settings)

    #expect(try AppPreviewSettingsPersistenceCodec.decode(from: data) == settings)
  }

  @Test func savingPreservesDuplicateResourceNames() throws {
    let workspace = WorkspaceDefinition(
      inputDevices: [WorkspaceInputDeviceRecord(name: "Shared", kind: .video)],
      visions: [WorkspaceVisionDefinition(name: "Shared")]
    )

    #expect(try WorkspacePersistenceCodec.encodeWorkspace(workspace).isEmpty == false)
  }

  @Test func decodingRejectsDuplicateResourceNamesAcrossKinds() throws {
    var inputDevice = Ldtx_Workspace_V3_InputDeviceRecord()
    inputDevice.name = "Shared"
    var vision = Ldtx_Workspace_V3_VisionRecord()
    vision.name = "Shared"
    var proto = Ldtx_Workspace_V3_Workspace()
    proto.formatVersion = WorkspacePersistenceCodec.formatVersion
    proto.lineageID = UUID().uuidString
    proto.outputConfiguration = validOutputConfiguration()
    proto.inputDevices = [inputDevice]
    proto.visions = [vision]

    #expect(throws: WorkspaceResourceNameValidationError.duplicateName("Shared")) {
      try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
    }
  }

  @Test func decodingRejectsDuplicateInputDeviceNames() throws {
    var first = Ldtx_Workspace_V3_InputDeviceRecord()
    first.name = "Duplicate Camera"
    var second = Ldtx_Workspace_V3_InputDeviceRecord()
    second.name = "Duplicate Camera"
    var proto = Ldtx_Workspace_V3_Workspace()
    proto.formatVersion = WorkspacePersistenceCodec.formatVersion
    proto.lineageID = UUID().uuidString
    proto.outputConfiguration = validOutputConfiguration()
    proto.inputDevices = [first, second]

    #expect(throws: WorkspaceResourceNameValidationError.duplicateName("Duplicate Camera")) {
      try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
    }
  }

  @Test func decodingRejectsDuplicateProgramNames() throws {
    let program = SavedProgramDefinitionRecord(
      name: "Gameplay",
      canvasWidth: 1920,
      canvasHeight: 1080,
      frameRateNumerator: 60,
      frameRateDenominator: 1,
      composite: CompositeProgramDefinition()
    )
    let workspace = WorkspaceDefinition(programs: [program, program])

    #expect(throws: WorkspaceIntegrityError.duplicateProgramName("Gameplay")) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingRejectsAnEmptyProgramName() throws {
    let program = SavedProgramDefinitionRecord(
      name: "",
      landscape: .emptyLandscape,
      portrait: .emptyPortrait)
    let workspace = WorkspaceDefinition(programs: [program])

    #expect(throws: WorkspaceIntegrityError.emptyProgramName) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingRejectsDuplicateCanvasAudioChannelNames() throws {
    let duplicate = ProgramAudioChannel(name: "Microphone", component: .silentAudio)
    let program = SavedProgramDefinitionRecord(
      name: "Gameplay",
      landscape: ProgramCanvasDefinition(
        canvasWidth: 1920,
        canvasHeight: 1080,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: CompositeProgramDefinition(audioChannels: [duplicate, duplicate])),
      portrait: .emptyPortrait)
    let workspace = WorkspaceDefinition(programs: [program])

    #expect(
      throws: WorkspaceIntegrityError.duplicateCanvasAudioChannelName(
        program: "Gameplay", canvas: "Landscape", channel: "Microphone")
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingRejectsDuplicateWorkspaceAudioChannelNames() throws {
    let duplicate = ProgramAudioChannel(name: "Microphone", component: .silentAudio)
    let workspace = WorkspaceDefinition(audioChannels: [duplicate, duplicate])

    #expect(throws: WorkspaceIntegrityError.duplicateWorkspaceAudioChannelName("Microphone")) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingWorkspaceWithPreferencesRejectsMissingSelectedProgram() throws {
    let workspace = WorkspaceDefinition(programs: [
      SavedProgramDefinitionRecord(
        name: "Gameplay",
        canvasWidth: 1920,
        canvasHeight: 1080,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: CompositeProgramDefinition()
      )
    ])
    let preferences = WorkspacePreferences(selectedProgramName: "Missing Program")

    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Workspace Preferences",
        reference: "Missing Program"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
        preferences: preferences
      )
    }
  }

  @Test func decodingAcceptsVideoInputDeviceAsDirectVideoLayer() throws {
    let workspace = WorkspaceDefinition(
      programs: [
        SavedProgramDefinitionRecord(
          name: "Gameplay",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition(steps: [
            CompositeProgramStep(
              displayName: "Capture",
              component: .inputCameraDevice(
                InputDeviceComponent(inputDeviceID: "Capture")
              )
            )
          ])
        )
      ],
      inputDevices: [
        WorkspaceInputDeviceRecord(name: "Capture", kind: .video)
      ]
    )
    var programPreferences = ProgramPreferences()
    programPreferences.setVideoLayers(
      [VideoLayerPreference(componentName: "Capture")],
      forProgramNamed: "Gameplay"
    )
    let preferences = WorkspacePreferences(programPreferences: programPreferences)

    let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
      preferences: preferences
    )

    #expect(
      snapshot.preferences.programPreferences.videoLayers(forProgramNamed: "Gameplay") == [
        VideoLayerPreference(componentName: "Capture")
      ])
  }

  @Test func decodingRejectsMissingCanvasVideoLayerPreference() throws {
    let program = SavedProgramDefinitionRecord(
      name: "Gameplay",
      landscape: ProgramCanvasDefinition(
        canvasWidth: 1_920,
        canvasHeight: 1_080,
        composite: CompositeProgramDefinition(steps: [
          CompositeProgramStep(
            displayName: "Capture",
            component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Capture"))
          )
        ])
      ),
      portrait: .emptyPortrait
    )
    let workspace = WorkspaceDefinition(
      programs: [program],
      inputDevices: [WorkspaceInputDeviceRecord(name: "Capture", kind: .video)]
    )

    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Landscape Video Layer Preferences for Gameplay",
        reference: "Capture"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
        preferences: WorkspacePreferences()
      )
    }
  }

  @Test func decodingRejectsCanvasCameraWithMissingInputDevice() throws {
    let camera = CompositeProgramStep(
      displayName: "Missing Camera",
      component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "missing-camera"))
    )
    let program = SavedProgramDefinitionRecord(
      name: "Gameplay",
      landscape: ProgramCanvasDefinition(
        canvasWidth: 1_920,
        canvasHeight: 1_080,
        composite: CompositeProgramDefinition(steps: [camera])
      ),
      portrait: .emptyPortrait
    )
    let workspace = WorkspaceDefinition(programs: [program])

    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Landscape Camera Missing Camera in Gameplay",
        reference: "missing-camera"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingRejectsCanvasCameraUsingAudioInputDevice() throws {
    let camera = CompositeProgramStep(
      displayName: "Wrong Camera",
      component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "microphone"))
    )
    let program = SavedProgramDefinitionRecord(
      name: "Gameplay",
      landscape: .emptyLandscape,
      portrait: ProgramCanvasDefinition(
        canvasWidth: 1_080,
        canvasHeight: 1_920,
        composite: CompositeProgramDefinition(steps: [camera])
      )
    )
    let workspace = WorkspaceDefinition(
      programs: [program],
      inputDevices: [WorkspaceInputDeviceRecord(name: "microphone", kind: .audio)]
    )

    #expect(
      throws: WorkspaceIntegrityError.incompatibleInputDevice(
        owner: "Portrait Camera Wrong Camera in Gameplay",
        inputDeviceID: "microphone",
        expectedKind: .video,
        actualKind: .audio
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingRejectsAudioInputDeviceAsDirectVideoLayer() throws {
    let workspace = WorkspaceDefinition(
      programs: [
        SavedProgramDefinitionRecord(
          name: "Gameplay",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition()
        )
      ],
      inputDevices: [WorkspaceInputDeviceRecord(name: "Microphone", kind: .audio)]
    )
    var programPreferences = ProgramPreferences()
    programPreferences.setVideoLayers(
      [VideoLayerPreference(componentName: "Microphone")],
      forProgramNamed: "Gameplay"
    )
    let preferences = WorkspacePreferences(programPreferences: programPreferences)

    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Video Layers for Gameplay",
        reference: "Microphone"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
        preferences: preferences
      )
    }
  }

  @Test func decodingRejectsMissingWorkspaceVideoPTSMaster() throws {
    let workspace = WorkspaceDefinition(
      outputConfiguration: WorkspaceOutputConfiguration(
        videoPTSMasterInputDeviceID: "Missing Camera"
      )
    )

    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Workspace Output Configuration",
        reference: "Missing Camera"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
      )
    }
  }

  @Test func decodingRejectsVideoComponentWithMissingInputDevice() throws {
    var component = Ldtx_Workspace_V3_VideoComponentRecord()
    component.name = "Camera"
    component.component = ProgramPersistenceCodec.encodeProgramComponent(
      .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Missing Camera"))
    )
    var proto = Ldtx_Workspace_V3_Workspace()
    proto.formatVersion = WorkspacePersistenceCodec.formatVersion
    proto.lineageID = UUID().uuidString
    proto.outputConfiguration = validOutputConfiguration()
    proto.videoComponents = [component]

    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Video Component Camera",
        reference: "Missing Camera"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
    }
  }

  @Test func persistenceOmitsWorkspaceVideoComponentDestination() throws {
    let workspace = WorkspaceDefinition(videoComponents: [
      WorkspaceVideoComponentRecord(
        name: "Camera Component",
        component: .inputCameraDevice(
          InputDeviceComponent(
            destinationX: 120,
            destinationY: 80,
            destinationScale: 0.5
          ))
      )
    ])

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
    )
    let component = try #require(decoded.definition.videoComponents.first?.component)
    let payload = try #require(inputDeviceComponent(in: component))

    #expect(payload.destination == InputDeviceDestination())
  }

  @Test func savingDropsLegacyWorkspaceVideoComponentDestination() throws {
    let workspace = WorkspaceDefinition(videoComponents: [
      WorkspaceVideoComponentRecord(
        name: "Camera Component",
        component: .inputCameraDevice(InputDeviceComponent(destinationX: 240))
      )
    ])

    let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
      from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
    )

    let component = try #require(decoded.definition.videoComponents.first?.component)
    #expect(inputDeviceComponent(in: component)?.destinationX == 0)
  }

  @Test func currentWorkspaceRejectsMissingVideoLayerPreferences() throws {
    let step = CompositeProgramStep(
      displayName: "Camera Component",
      component: .inputCameraDevice(InputDeviceComponent(destinationX: 240))
    )
    let workspace = WorkspaceDefinition(programs: [
      SavedProgramDefinitionRecord(
        name: "Main",
        canvasWidth: 1920,
        canvasHeight: 1080,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: CompositeProgramDefinition(steps: [step])
      )
    ])
    #expect(
      throws: WorkspaceIntegrityError.missingReference(
        owner: "Landscape Video Layer Preferences for Main",
        reference: "Camera Component"
      )
    ) {
      try WorkspacePersistenceCodec.decodeWorkspace(
        from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
        preferences: WorkspacePreferences()
      )
    }
  }

  @Test func workspaceJSONRoundTripsThroughProtobufPersistence() throws {
    let videoStep = CompositeProgramStep(
      component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Camera"))
    )
    let workspace = WorkspaceDefinition(
      name: "JSON Mirror",
      programs: [
        SavedProgramDefinitionRecord(
          name: "JSON Program",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition(steps: [videoStep])
        )
      ],
      inputDevices: [
        WorkspaceInputDeviceRecord(
          name: "Camera",
          kind: .video,
          captureWidthOverride: 1280,
          captureHeightOverride: 720,
          captureFrameRateOverride: 30
        ),
        WorkspaceInputDeviceRecord(
          id: "Commentary",
          name: "Commentary",
          kind: .audio,
        ),
      ],
      audioChannels: [
        ProgramAudioChannel(
          component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Commentary"))
        )
      ],
      videoComponents: [
        WorkspaceVideoComponentRecord(
          name: videoStep.name,
          inputDeviceID: "Camera"
        )
      ]
    )

    var programPreferences = ProgramPreferences()
    programPreferences.setVideoLayers(
      [VideoLayerPreference(componentName: videoStep.name)],
      forProgramNamed: "JSON Program"
    )
    let preferences = WorkspacePreferences(programPreferences: programPreferences)
    let data = try WorkspacePersistenceCodec.encodeWorkspaceJSON(workspace)
    let decoded = try WorkspacePersistenceCodec.decodeWorkspaceJSON(
      from: data,
      preferences: preferences
    )

    #expect(decoded.definition == workspace)
    #expect(decoded.preferences == preferences)
  }

  @Test func audioInputsRemainEligibleForSideTrackRecording() {
    let inputDevice = WorkspaceInputDeviceRecord(name: "Mic", kind: .audio)

    #expect(inputDevice.kind == .audio)
  }

  @Test func unspecifiedBackgroundRemovalPolicyDoesNotRemoveBackgroundByDefault() {
    let inputDevice = WorkspaceInputDeviceRecord(name: "Camera", kind: .video)

    #expect(!inputDevice.removesBackground)
  }

  private func inputDeviceComponent(in component: ProgramComponent) -> InputDeviceComponent? {
    guard case .inputCameraDevice(let payload) = component else { return nil }
    return payload
  }

  private func validOutputConfiguration() -> Ldtx_Workspace_V3_WorkspaceOutputConfiguration {
    var configuration = Ldtx_Workspace_V3_WorkspaceOutputConfiguration()
    configuration.landscapeProfileID = WorkspaceOutputProfileID.sdrLandscape1080p60.rawValue
    configuration.portraitProfileID = WorkspaceOutputProfileID.sdrPortrait1080p60.rawValue
    configuration.frameRate = 60
    configuration.landscapeVideoBitRate = 6_000_000
    configuration.portraitVideoBitRate = 6_000_000
    return configuration
  }
}
