<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# XcodeGen test classification audit

`AGENTS.md` is the classification source of truth. This inventory covers XcodeGen-managed Swift Testing suites only. The XCTest app integration target, SwiftPM tests, and CMake tests are excluded. Resource labels below are source-scan signals for review, not automatic tier decisions.

## Classification decisions in this change

- Lightweight tests that exercise temporary filesystem packages, SQLite, diagnostic log files, local DASH files, or an AppAuth loopback listener are assigned to `LDTXMediumTests`. The `ActiveProgramOutputSessionIntegrationTestSuite` is also Medium because it creates temporary recording packages and exercises the file-backed recording lifecycle with controlled media.
- GPU, AVFoundation encoding, substantial media processing, and runtime media suites remain Hard. They are not moved to Medium just because they also use temporary output files.
- Other deterministic state/value tests remain Easy. Controlled fake-based component interaction remains Easy Integration when it has no demanding external resource.
- The former shared `LDTXSystemTestSuite` serialized suites were not System isolation targets. Their cases are now ordinary Integration suites. The AVAssetWriter tests keep a SUT-specific serialized Integration parent because they share the process-wide lifecycle gate and segment delegate; the production gate coordinates writer transitions. The remaining formerly grouped tests use controlled fakes and need no shared serialized parent. No current suite was found to require a dedicated SystemTests target. Revisit if a test demonstrates unsafe cross-target shared state.
- Suite naming expresses Unit or Integration scope. `.serialized` remains on the AVAssetWriter lifecycle parent and two Hard media/runtime suites where their own cases need ordered execution; it does not imply System classification.

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
| Easy | `ProgramComponentPersistenceUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Program/ProgramComponentPersistenceTests.swift` |
| Easy | `ProgramDefinitionPersistenceUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Program/ProgramPersistenceCodecTests.swift` |
| Easy | `ProgramPreferencesPersistenceUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Program/ProgramPreferencesPersistenceTests.swift` |
| Easy | `ProgramPreferencesUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Program/ProgramPreferencesTests.swift` |
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
| Easy | `WorkspaceV4PersistenceCodecUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXEasyTests/Workspace/WorkspaceV4PersistenceCodecTests.swift` |
| Easy | `WorkspaceV4StoreUnitTestSuite` | Unit | media/framework | `Tests/LDTXEasyTests/Workspace/WorkspaceV4StoreTests.swift` |
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
| Medium | `WorkspaceV4PackageServiceIntegrationTestSuite` | Integration | filesystem, media/framework | `Tests/LDTXMediumTests/Workspace/WorkspaceV4PackageServiceTests.swift` |
| Medium | `GoogleOAuthLoopbackListenerIntegrationTestSuite` | Integration | loopback/socket | `Tests/LDTXMediumTests/YouTubeAuth/GoogleOAuthLoopbackListenerTests.swift` |
| Hard | `BackgroundRemovalInferenceGateIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXHardTests/BackgroundSegmentation/BackgroundRemovalInferenceGateTests.swift` |
| Hard | `AVAssetWriterLifecycleIntegrationTestSuite` | Integration | AVAssetWriter lifecycle and shared segment delegate (parent suite; inherited by child suites) | `Tests/LDTXHardTests/Integration/AVAssetWriterLifecycleIntegrationTestSuite.swift` |
| Hard | `AudioSideStreamSegmentPipelineIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXHardTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Hard | `H264VideoEncoderIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXHardTests/Integration/H264VideoEncoderTests.swift` |
| Hard | `ProgramRenderingOrderIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXHardTests/Program/ProgramRenderingOrderTests.swift` |
| Hard | `ClockOverlayRuntimeIntegrationTestSuite` | Integration | filesystem, media/framework, controlled concurrency | `Tests/LDTXHardTests/ProgramRuntime/ClockOverlayRuntimeTests.swift` |
| Hard | `ManualCapturePipelineIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXHardTests/ProgramRuntime/ManualCapturePipelineTests.swift` |
| Hard | `VideoInputPreprocessingIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXHardTests/ProgramRuntime/VideoInputPreprocessingTests.swift` |
| Hard | `YouTubeOutputMediaSampleConverterIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXHardTests/ProgramRuntime/YouTubeOutputMediaSampleConverterTests.swift` |
| Hard | `YouTubeRTMPSWorkspaceServiceIntegrationTestSuite` | Integration | media/framework, controlled concurrency | `Tests/LDTXHardTests/ProgramRuntime/YouTubeRTMPSWorkspaceServiceTests.swift` |
| Hard | `VideoCompositorIntegrationTestSuite` | Integration | media/framework | `Tests/LDTXHardTests/VideoRendering/VideoCompositorTests.swift` |
| Hard | `YouTubeAuthorizationServiceIntegrationTestSuite` | Integration | none detected by source scan | `Tests/LDTXHardTests/YouTubeAuth/YouTubeAuthorizationServiceKeychainTests.swift` |
| AppLifecycleEasy | `WorkspaceV4VisionFeatureUnitTestSuite` | Unit | media/framework | `Tests/LDTXAppLifecycleEasyTests/App/AppFeatureProviderUnitTestSuite.swift` |
| AppLifecycleEasy | `AudioMixRoutingUnitTestSuite` | Unit | media/framework | `Tests/LDTXAppLifecycleEasyTests/App/AudioMixRoutingTests.swift` |
| AppLifecycleEasy | `LDTXRuntimeModeUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXAppLifecycleEasyTests/App/LDTXRuntimeModeTests.swift` |
| AppLifecycleEasy | `LocalOutputServiceIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXAppLifecycleEasyTests/App/LocalOutputServiceTests.swift` |
| AppLifecycleEasy | `OutputSettingsModelIntegrationTestSuite` | Integration | isolated UserDefaults domain | `Tests/LDTXAppLifecycleEasyTests/App/OutputSettingsModelTests.swift` |
| AppLifecycleEasy | `ProgramLibraryUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXAppLifecycleEasyTests/App/ProgramLibraryTests.swift` |
| AppLifecycleEasy | `ProgramPreferencesStoreUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXAppLifecycleEasyTests/App/ProgramPreferencesStoreTests.swift` |
| AppLifecycleEasy | `ProgramRuntimeStateUnitTestSuite` | Unit | none detected by source scan | `Tests/LDTXAppLifecycleEasyTests/App/ProgramRuntimeStateTests.swift` |
| AppLifecycleEasy | `RecordingMarkerStoreIntegrationTestSuite` | Integration | filesystem, media/framework | `Tests/LDTXAppLifecycleEasyTests/App/RecordingMarkerStoreTests.swift` |
| AppLifecycleEasy | `WorkspaceShutdownCoordinatorIntegrationTestSuite` | Integration | controlled concurrency | `Tests/LDTXAppLifecycleEasyTests/App/WorkspaceShutdownCoordinatorTests.swift` |
| AppLifecycleEasy | `WorkspaceV4PersistenceCoordinatorIntegrationTestSuite` | Integration | filesystem | `Tests/LDTXAppLifecycleEasyTests/App/WorkspaceV4PersistenceCoordinatorTests.swift` |
| AppLifecycleEasy | `WorkspaceV4RuntimeSessionIntegrationTestSuite` | Integration | filesystem, media/framework | `Tests/LDTXAppLifecycleEasyTests/App/WorkspaceV4RuntimeSessionTests.swift` |
| AppLifecycleEasy | `YouTubeAuthStateIntegrationTestSuite` | Integration | filesystem, controlled concurrency | `Tests/LDTXAppLifecycleEasyTests/App/YouTubeAuthStateTests.swift` |
| AppLifecycleHard | `CanvasPairPreviewIntegrationTestSuite` | Integration | media/framework, app UI | `Tests/LDTXAppLifecycleHardTests/App/CanvasPairPreviewTests.swift` |
| AppLifecycleHard | `PaneSplitViewIntegrationTestSuite` | Integration | app UI | `Tests/LDTXAppLifecycleHardTests/App/PaneSplitViewTests.swift` |
| AppLifecycleHard | `WindowLifecycleIntegrationTestSuite` | Integration | app UI | `Tests/LDTXAppLifecycleHardTests/App/WindowLifecycleTests.swift` |

## AppLifecycle structure and policy review

AppLifecycle suites remain in their existing app-hosted Easy and Hard targets in this change. Both targets set `TEST_HOST` to `LDTX.app` and use `BUNDLE_LOADER`; they also depend on app and applet modules. App-hosting is therefore a target-wide current property, not proof that every suite needs full application startup. Determine whether the host is required per suite by checking symbol ownership, `@testable` visibility, initialization side effects, and whether the suite can link its owning module directly.

| Current target | Suite | Observed concern | Follow-up classification question |
|---|---|---|---|
| AppLifecycleEasy | `OutputSettingsModelIntegrationTestSuite` | UserDefaults suite and settings persistence | Can the settings model be tested from a non-host target with isolated defaults? |
| AppLifecycleEasy | `ProgramRuntimeStateUnitTestSuite`, `AudioMixRoutingUnitTestSuite` | Pure state/routing behavior | Can the owning runtime module be tested without loading the app executable? |
| AppLifecycleEasy | `WorkspaceV4RuntimeSessionIntegrationTestSuite`, `WorkspaceV4PersistenceCoordinatorIntegrationTestSuite` | Temporary workspace files and applet orchestration | Is app hosting needed for implementation symbols, or can the applet module own the test target? If retained as hosted, how should Medium resource tiering be represented? |
| AppLifecycleEasy | `RecordingMarkerStoreIntegrationTestSuite`, `LocalOutputServiceIntegrationTestSuite` | AVFoundation metadata and temporary filesystem | Can these move to non-host Medium tests while preserving access to their owning modules? |
| AppLifecycleEasy | `YouTubeAuthStateIntegrationTestSuite` | Settings model state and async callbacks; temporary persistence paths | Which behaviors are module-level and which actually require the app host? |
| AppLifecycleEasy | `WorkspaceShutdownCoordinatorIntegrationTestSuite` | Main actor and asynchronous shutdown callbacks | Does app hosting contribute behavior under test, or only symbol access? |
| AppLifecycleEasy | Remaining Unit suites (`WorkspaceV4VisionFeature`, `LDTXRuntimeMode`, `ProgramLibrary`, `ProgramPreferencesStore`, `ProgramRuntimeState`, `AudioMixRouting`) | App/applet model symbols; no UI window in test source | Can tests link applet/runtime modules directly, and should suite names remain Unit after extraction? |
| AppLifecycleHard | `CanvasPairPreviewIntegrationTestSuite` | Metal and drawable/rendering resources | Keep Hard; determine whether app-hosting is needed beyond app symbol access. |
| AppLifecycleHard | `PaneSplitViewIntegrationTestSuite`, `WindowLifecycleIntegrationTestSuite` | AppKit/SwiftUI windows and main-thread UI | Keep isolated from headless suites if UI process state is shared; decide whether a dedicated app lifecycle System target is warranted after independent-run analysis. |

### Recommended AppLifecycle policy

Treat app-host requirement as an execution constraint, separate from Easy,
Medium, and Hard. For each suite, first verify whether it needs app startup or
only imports an app/applet symbol. Move module-owned tests that can link and
run without the app host into the ordinary tier targets. Keep the app-hosted
group limited to tests that exercise application startup, app-owned lifecycle,
or behavior that demonstrably depends on the loaded app process.

Then assign the remaining hosted suites a resource tier using the same AGENTS
criteria. If a hosted suite needs only a temporary directory or isolated
UserDefaults domain, it is a Medium candidate; Metal, real window/UI state, or
substantial media work remains Hard. Add an AppLifecycle Medium target only if
the audit finds Medium cases that still require the app host. Create a
SystemTests target only for a specific SUT whose shared application/UI state
cannot be safely handled as ordinary hosted Integration tests. AppKit use or
`TEST_HOST` by itself is not sufficient evidence for System isolation.

Complete this audit with a target dependency graph and a per-suite standalone
run check before changing AppLifecycle file placement or target definitions.
