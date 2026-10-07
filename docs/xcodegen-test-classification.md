<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# XcodeGen test classification audit

`AGENTS.md` is the classification source of truth. This inventory covers XcodeGen-managed Swift Testing suites. SwiftUI View-value and direct AppKit tests share the UI component target. UI automation, XPC tests, SwiftPM tests, and CMake tests keep separate execution boundaries. Resource labels below are source-scan signals for review, not automatic tier decisions.

## Classification decisions in this change

- Lightweight tests that exercise temporary filesystem packages, SQLite, diagnostic log files, local DASH files, or an AppAuth loopback listener are assigned to `LDTXMediumTests`. The `ActiveProgramOutputSessionIntegrationTestSuite` is also Medium because it creates temporary recording packages and exercises the file-backed recording lifecycle with controlled media.
- GHA-compatible Metal, AVFoundation encoding, media processing, runtime media, and Keychain suites are Medium. Hard contains only the real Clock OCR test, which requires the Xcode Cloud environment.
- Other deterministic state/value tests remain Easy. Controlled fake-based component interaction remains Easy Integration when it has no external resource.
- The former shared `LDTXSystemTestSuite` serialized suites were not System isolation targets. Their cases are now ordinary Integration suites. The AVAssetWriter tests keep a SUT-specific serialized Integration parent because they share the process-wide lifecycle gate and segment delegate; the production gate coordinates writer transitions. The remaining formerly grouped tests use controlled fakes and need no shared serialized parent. Direct AppKit window/controller and Document tests share the hostless `LDTXAppUIComponentTests` target and its serialized MainActor parent suite.
- Shared Corelibs suites run in `LDTXCorelibsTests` under both XcodeGen and SwiftPM. Their sources live in `Tests/Corelibs/<module>Tests`.
- Suite naming expresses Unit or Integration scope. `.serialized` remains on the AVAssetWriter lifecycle parent and media/runtime suites where their own cases need ordered execution; it does not imply System classification.

## Suite inventory

`Resource signals` lists APIs or frameworks detected in the suite source. An empty signal means the source scan found none of the listed resources; it does not replace behavioral review.

| Current tier / target | Suite | Scope | Resource signals | Source |
|---|---|---|---|---|
| Easy | `AudioMixEngineUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/AudioEngine/AudioMixEngineTests.swift` |
| Easy | `CaptureSessionRuntimeFailurePolicyUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Capture/CaptureSessionRuntimeFailurePolicyTests.swift` |
| Easy | `CaptureSessionStartupSequenceUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Capture/CaptureSessionStartupSequenceTests.swift` |
| Easy | `CaptureWarmupGateUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Capture/CaptureWarmupGateTests.swift` |
| Easy | `SharedCaptureSessionPlannerUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Capture/SharedCaptureSessionPlannerTests.swift` |
| Easy | `DASHIngestEndpointUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Dash/DASHIngestEndpointTests.swift` |
| Easy | `DASHLiveUploadPipelineUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Dash/DASHLiveUploadPipelineTests.swift` |
| Easy | `DASHManifestUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Dash/DASHManifestTests.swift` |
| Easy | `DASHUploadClientUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Dash/DASHUploadClientTests.swift` |
| Easy | `DASHUploadFinalizationStateUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Dash/DASHUploadFinalizationStateTests.swift` |
| Easy | `LowFrequencyUpdateRegistryIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/Integration/LowFrequencyUpdateRegistryTests.swift` |
| Easy | `WorkspaceCaptureSessionCoordinatorIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXEasyTests/Integration/WorkspaceCaptureSessionCoordinatorTests.swift` |
| Easy | `YouTubeOutputMediaBatcherIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXEasyTests/Integration/YouTubeOutputMediaBatcherTests.swift` |
| Easy | `YouTubeOutputServiceProcessClientIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/Integration/YouTubeOutputServiceProcessClientTests.swift` |
| Easy | `YouTubeOutputWorkspaceServiceIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/Integration/YouTubeOutputWorkspaceServiceTests.swift` |
| Easy | `MP4TimingBoxUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/MP4/MP4TimingBoxTests.swift` |
| Easy | `AudioChannelTimelineUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/MediaTiming/AudioChannelTimelineTests.swift` |
| Easy | `AudioFramePTSClockUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/MediaTiming/AudioFramePTSClockTests.swift` |
| `LDTXCorelibsTests` | `ProgramComponentPersistenceUnitTestSuite` | Unit | none detected by source scan | `Tests/Corelibs/LDTXProgramTests/ProgramComponentPersistenceTests.swift` |
| `LDTXCorelibsTests` | `ProgramPreferencesUnitTestSuite` | Unit | none detected by source scan | `Tests/Corelibs/LDTXProgramTests/ProgramPreferencesTests.swift` |
| Easy | `DASHStreamContinuityUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/DASHStreamContinuityTests.swift` |
| Easy | `ProgramAudioInputPassthroughUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/ProgramAudioInputPassthroughTests.swift` |
| Easy | `ProgramAudioMonitorMixerIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXEasyTests/ProgramRuntime/ProgramAudioMonitorMixerTests.swift` |
| Easy | `ProgramFrameDeliveryIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXEasyTests/ProgramRuntime/ProgramFrameDeliveryTests.swift` |
| Easy | `ProgramFramePacerUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/ProgramFramePacerTests.swift` |
| Easy | `ProgramOutputMediaHubIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXEasyTests/ProgramRuntime/ProgramOutputMediaHubTests.swift` |
| Easy | `ProgramOutputProfileUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/ProgramOutputProfileTests.swift` |
| Easy | `ProgramOutputSharedH264ServiceIntegrationTestSuite` | Integration | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/ProgramOutputSharedH264ServiceTests.swift` |
| Easy | `ProgramOutputVideoTimelineUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/ProgramRuntime/ProgramOutputVideoTimelineTests.swift` |
| Easy | `ProgramRuntimePreferencesUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/ProgramRuntimePreferencesTests.swift` |
| Easy | `ProgramVideoPTSSelectorHostClockIntegrationTestSuite` | Integration | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/ProgramVideoPTSSelectorHostClockTests.swift` |
| Easy | `ProgramVideoPTSSelectorUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/ProgramRuntime/ProgramVideoPTSSelectorTests.swift` |
| Easy | `RecordingTimelineNormalizerUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/ProgramRuntime/RecordingTimelineNormalizerTests.swift` |
| Easy | `SessionRecordAudioTrackUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/SessionRecordAudioTrackTests.swift` |
| Easy | `YouTubeOutputMediaBacklogUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/YouTubeOutputMediaBacklogTests.swift` |
| Easy | `YouTubeOutputRecoveryPolicyUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/ProgramRuntime/YouTubeOutputRecoveryPolicyTests.swift` |
| Easy | `BackgroundTaskQueueCancellationIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/TaskQueue/BackgroundTaskQueueCancellationTests.swift` |
| Easy | `SessionTaskQueueIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/TaskQueue/BackgroundTaskQueueTests.swift` |
| Easy | `EventTaskQueueIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/TaskQueue/EventTaskQueueTests.swift` |
| Easy | `ResourceTaskQueueIntegrationTestSuite` | Integration | none detected by source scan | `Tests/LDTXEasyTests/TaskQueue/ResourceTaskQueueTests.swift` |
| Easy | `WorkspaceResourceQueueIntegrationTestSuite` | Integration | none detected by source scan | `Tests/LDTXEasyTests/TaskQueue/WorkspaceResourceQueueTests.swift` |
| Easy | `VisionFramePoolUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/Vision/VisionFramePoolTests.swift` |
| Easy | `WorkspaceLocalStateUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Workspace/WorkspaceLocalStateTests.swift` |
| Easy | `WorkspaceResourcePathComponentCodecUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Workspace/WorkspaceResourcePathComponentCodecTests.swift` |
| Easy | `YouTubeLiveAPIClientUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/YouTube/YouTubeLiveAPIClientTests.swift` |
| Easy | `GoogleOAuthClientConfigurationUnitTestSuite` | Unit | loopback/socket | `Tests/LDTXEasyTests/YouTubeAuth/GoogleOAuthClientConfigurationTests.swift` |
| Easy | `YouTubeOutputProtocolUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/YouTubeOutputProtocol/YouTubeOutputProtocolTests.swift` |
| Easy | `YouTubeOutputVideoFrameHoldUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/YouTubeOutputProtocol/YouTubeOutputVideoFrameHoldTests.swift` |
| Easy | `FLVPacketEncoderUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/YouTubeRTMPS/FLVPacketEncoderTests.swift` |
| Easy | `RTMPEncodingUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/YouTubeRTMPS/RTMPEncodingTests.swift` |
| Easy | `YouTubeRTMPSPublisherIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/YouTubeRTMPS/YouTubeRTMPSPublisherTests.swift` |
| Easy | `YouTubeRTMPSStreamKeyConfigurationUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/YouTubeRTMPS/YouTubeRTMPSStreamKeyConfigurationTests.swift` |
| Medium | `DASHLocalFilePipelineIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/Dash/DASHLocalFilePipelineTests.swift` |
| Medium | `DiagnosticsDatabaseIntegrationTestSuite` | Integration | filesystem, SQLite | `Tests/LDTXMediumTests/Diagnostics/DiagnosticsDatabaseTests.swift` |
| Medium | `EventTaskLoggerIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/Diagnostics/EventTaskLoggerTests.swift` |
| Medium | `ActiveProgramOutputSessionIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXMediumTests/ProgramRuntime/ActiveProgramOutputSessionTests.swift` |
| Medium | `DualCanvasRecordingPackageIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/ProgramRuntime/DualCanvasRecordingPackageTests.swift` |
| Medium | `RecordingDiagnosticsEventLogIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/Recording/RecordingDiagnosticsEventLogTests.swift` |
| Medium | `RecordingPackageIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/Recording/RecordingPackageTests.swift` |
| Medium | `RecordingShieldIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/Recording/RecordingShieldTests.swift` |
| `LDTXCorelibsTests` | `WorkspaceBundleFormatIntegrationTestSuite` | Integration | filesystem, media/framework | `Tests/Corelibs/LDTXWorkspaceBundleFormatTests/WorkspaceBundleFormatTests.swift` |
| Medium | `GoogleOAuthLoopbackListenerIntegrationTestSuite` | Integration | loopback/socket | `Tests/LDTXMediumTests/YouTubeAuth/GoogleOAuthLoopbackListenerTests.swift` |
| Medium | `BackgroundRemovalInferenceGateIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXMediumTests/BackgroundSegmentation/BackgroundRemovalInferenceGateTests.swift` |
| Medium | `AVAssetWriterLifecycleIntegrationTestSuite` | Integration | AVAssetWriter lifecycle and shared segment delegate (parent suite; inherited by child suites) | `Tests/LDTXMediumTests/Integration/AVAssetWriterLifecycleIntegrationTestSuite.swift` |
| Medium | `AudioSideStreamSegmentPipelineIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXMediumTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Medium | `H264VideoEncoderIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXMediumTests/Integration/H264VideoEncoderTests.swift` |
| Medium | `ProgramRenderingOrderIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXMediumTests/Program/ProgramRenderingOrderTests.swift` |
| Medium | `ClockOverlayRuntimeIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXMediumTests/ProgramRuntime/ClockOverlayRuntimeTests.swift` |
| Medium | `ManualCapturePipelineIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXMediumTests/ProgramRuntime/ManualCapturePipelineTests.swift` |
| Medium | `VideoInputPreprocessingIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXMediumTests/ProgramRuntime/VideoInputPreprocessingTests.swift` |
| Medium | `YouTubeOutputMediaSampleConverterIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXMediumTests/ProgramRuntime/YouTubeOutputMediaSampleConverterTests.swift` |
| Medium | `YouTubeRTMPSWorkspaceServiceIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXMediumTests/ProgramRuntime/YouTubeRTMPSWorkspaceServiceTests.swift` |
| Medium | `VideoCompositorIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXMediumTests/VideoRendering/VideoCompositorTests.swift` |
| Medium | `YouTubeAuthorizationServiceIntegrationTestSuite` | Integration | none detected by source scan | `Tests/LDTXMediumTests/YouTubeAuth/YouTubeAuthorizationServiceKeychainTests.swift` |
| Easy | `WorkspaceV4VisionFeatureUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/App/WorkspaceV4VisionFeatureTests.swift` |
| Easy | `AudioMixRoutingUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/App/AudioMixRoutingTests.swift` |
| Easy | `ProgramPairPreviewRegionsUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/ProgramPairPreviewRegionsTests.swift` |
| Easy | `OutputSettingsModelUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/OutputSettingsModelTests.swift` |
| Easy | `WorkspaceV4RenderGraphUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/WorkspaceV4RenderGraphTests.swift` |
| Medium | `LocalOutputServiceIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/App/LocalOutputServiceTests.swift` |
| Medium | `ApplicationSettingsStoreIntegrationTestSuite` | Integration | isolated UserDefaults domain | `Tests/LDTXMediumTests/App/OutputSettingsModelTests.swift` |
| Easy | `ProgramLibraryUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/ProgramLibraryTests.swift` |
| Easy | `ProgramPreferencesStoreUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/ProgramPreferencesStoreTests.swift` |
| Easy | `ProgramRuntimeStateUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/ProgramRuntimeStateTests.swift` |
| Medium | `RecordingMarkerStoreIntegrationTestSuite` | Integration | filesystem, media/framework | `Tests/LDTXMediumTests/App/RecordingMarkerStoreTests.swift` |
| Easy | `WorkspaceShutdownCoordinatorIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/App/WorkspaceShutdownCoordinatorTests.swift` |
| Easy | `ApplicationTerminationCoordinatorIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXEasyTests/App/ApplicationTerminationCoordinatorTests.swift` |
| Easy | `RuntimeModeUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/App/RuntimeModeTests.swift` |
| Medium | `WorkspaceV4PersistenceCoordinatorIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXMediumTests/App/WorkspaceV4PersistenceCoordinatorTests.swift` |
| Medium | `WorkspaceWindowRuntimeIntegrationTestSuite` | Integration | filesystem, media/framework | `Tests/LDTXMediumTests/App/WorkspaceWindowRuntimeTests.swift` |
| Medium | `YouTubeAuthStateIntegrationTestSuite` | Integration | filesystem, controlled concurrency | `Tests/LDTXMediumTests/App/YouTubeAuthStateTests.swift` |
| Medium | `ProgramPairPreviewRendererIntegrationTestSuite` | Integration | media/framework, Metal | `Tests/LDTXMediumTests/VideoRendering/ProgramPairPreviewRendererTests.swift` |
| App UI component | `SwiftUIViewStateUnitTestSuite` | Unit | SwiftUI View values, bindings, and derived state | `Tests/LDTXAppUIComponentTests/SwiftUIViewStateTests.swift` |
| App UI component | `PaneSplitViewControllerUnitTestSuite` | Unit | AppKit window and split constraints | `Tests/LDTXAppUIComponentTests/SplitView/PaneSplitViewControllerTests.swift` |
| App UI component | `WorkspaceToolbarIntegrationTestSuite` | Integration | AppKit window restoration and split state | `Tests/LDTXAppUIComponentTests/WorkspaceController/WorkspaceToolbarTests.swift` |
| App UI component | `VideoLayersEditorIntegrationTestSuite` | Integration | layer editor, selection, sheets, observation, and meters | `Tests/LDTXAppUIComponentTests/VideoLayers/VideoLayersEditorTests.swift` |
| App UI component | `DocumentEnvironmentIntegrationTestSuite` | Integration | hosted document references and ownership | `Tests/LDTXAppUIComponentTests/DocumentEnvironment/DocumentEnvironmentTests.swift` |
| App UI component | `WorkspaceErrorPresentationIntegrationTestSuite` | Integration | error sheets and queue lifetime | `Tests/LDTXAppUIComponentTests/WorkspaceController/WorkspaceErrorPresentationTests.swift` |
| App UI component | `WorkspaceOutputStateUnitTestSuite` | Unit | output state predicates | `Tests/LDTXAppUIComponentTests/WorkspaceController/WorkspaceOutputStateTests.swift` |
| App UI component | `WorkspaceDocumentIntegrationTestSuite` | Integration | open, save, close, and restoration | `Tests/LDTXAppUIComponentTests/WorkspaceDocument/WorkspaceDocumentTests.swift` |
| App UI component | `RecordPlayerDocumentIntegrationTestSuite` | Integration | recording ownership, marker saving, and close confirmation | `Tests/LDTXAppUIComponentTests/RecordPlayerDocument/RecordPlayerDocumentTests.swift` |
| UI automation | `AppLaunchUITests` | Integration | normal launch and main-menu access | `Tests/LDTXAppUITests/AppLaunchUITests.swift` |
| Medium | `WorkspaceVideoComponentVisionIntegrationTestSuite` | Integration | component rendering, ROI, controlled capture sources | `Tests/LDTXMediumTests/ProgramRuntime/WorkspaceVideoComponentVisionTests.swift` |
| Medium | `WorkspaceProgramSwitchingIntegrationTestSuite` | Integration | filesystem, recording lifecycle | `Tests/LDTXMediumTests/Workspace/WorkspaceProgramSwitchingTests.swift` |
| Hard | `WorkspaceVideoComponentVisionIntegrationTestSuite.clockOutputIsRecognized` | Integration | app-hosted Vision OCR with inference entitlement | `Tests/LDTXHardTests/ProgramRuntime/WorkspaceVideoComponentVisionTests.swift` |

## Execution-boundary targets

- `LDTXAppUIComponentTests` is a hostless bundle for SwiftUI state, Video Layers, split views, document environments, Workspace controllers, Workspace Documents, and Recording Documents. All child suites initialize one shared Document Controller and run under `AppUIComponentTestSuite`, serialized on MainActor.
- `LDTXAppUITests` is an independent UI automation target for normal application launch and main-menu smoke tests.
- `LDTXAppXpcTests` remains a separate app-hosted target for testing the embedded XPC process boundary.
- Application termination coordination remains a headless Easy integration suite.

## Xcode Cloud boundary

`WorkspaceVideoComponentVisionIntegrationTestSuite.clockOutputIsRecognized`
remains in `Tests/LDTXHardTests/ProgramRuntime/WorkspaceVideoComponentVisionTests.swift`.
It runs without a hardware-based skip in `LDTXApp`, whose normal signature and
profile authorize background inference. The component rendering, ROI, effects,
and unavailable-source cases are Medium. `GitHubActions.xctestplan` runs the GHA
coverage; `Default.xctestplan` retains the same targets for local use, and
`XcodeCloud.xctestplan` runs only HardTests.
