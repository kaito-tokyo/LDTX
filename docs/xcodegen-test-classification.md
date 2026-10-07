<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# XcodeGen test classification inventory

`AGENTS.md` is the source of truth. Classify the APIs exercised by each test and
its SUT, rather than imports, computational cost, permissions, or CI availability.
Unit and Integration scope is independent of the Easy, Medium, and Hard tiers.
Output-related suites use the macOS-only, hostless `LDTXOutputTests` target,
including logic, media processing, and service integration. XPC process
isolation tests remain in `LDTXAppXpcTests`.

- Easy contains pure logic, including controlled fake-based interactions and
  serialization that do not execute platform APIs.
- Medium contains macOS API tests, including filesystem, SQLite, Keychain,
  AppAuth loopback, CoreGraphics, CoreAudio, AudioToolbox, CoreMedia, CoreVideo,
  CoreImage, and non-View SwiftUI value APIs. CoreImage image copying does not
  itself exercise Vision OCR.
- Hard contains tests exercising Vision, VideoToolbox, CoreML, Metal, or
  AVFoundation. This includes SUT initialization that creates a Metal device,
  such as `ProgramRuntime`, even when capture sources are controlled fakes.
  Mixed suites stay in Hard when any case exercises a Hard framework.

The AVAssetWriter lifecycle parent and its extensions remain together in OutputTests
under `OutputTestSuite`
with their serialized execution control. Serialization does not create a
SystemTests isolation boundary.

All three tier targets are hostless. Xcode Cloud runs the hostless targets through
the `LDTXApp` scheme and `LDTXTests` plan. Only `LDTXAppUITests` uses XCUI,
and only XpcTests may use an application host. UI component and Corelibs target boundaries are unchanged.

## Tier suite inventory

Paths are relative to the repository root. The listed tier includes dependencies
exercised through the SUT, even when they do not appear as imports in the test.

| Tier | Suite | Source |
| --- | --- | --- |
| Easy | `ApplicationTerminationCoordinatorIntegrationTestSuite` | `Tests/LDTXEasyTests/App/ApplicationTerminationCoordinatorTests.swift` |
| Output | `OutputSettingsModelUnitTestSuite` | `Tests/LDTXOutputTests/App/OutputSettingsModelTests.swift` |
| Easy | `ProgramLibraryUnitTestSuite` | `Tests/LDTXEasyTests/App/ProgramLibraryTests.swift` |
| Easy | `ProgramPairPreviewRegionsUnitTestSuite` | `Tests/LDTXEasyTests/App/ProgramPairPreviewRegionsTests.swift` |
| Easy | `ProgramPreferencesStoreUnitTestSuite` | `Tests/LDTXEasyTests/App/ProgramPreferencesStoreTests.swift` |
| Easy | `ProgramRuntimeStateUnitTestSuite` | `Tests/LDTXEasyTests/App/ProgramRuntimeStateTests.swift` |
| Easy | `WorkspaceResourceAdditionUnitTestSuite` | `Tests/LDTXEasyTests/App/WorkspaceResourceAdditionTests.swift` |
| Easy | `WorkspaceSelectionUnitTestSuite` | `Tests/LDTXEasyTests/App/WorkspaceSelectionTests.swift` |
| Easy | `WorkspaceShutdownCoordinatorIntegrationTestSuite` | `Tests/LDTXEasyTests/App/WorkspaceShutdownCoordinatorTests.swift` |
| Easy | `WorkspaceV4RenderGraphUnitTestSuite` | `Tests/LDTXEasyTests/App/WorkspaceV4RenderGraphTests.swift` |
| Easy | `WorkspaceV4VisionFeatureUnitTestSuite` | `Tests/LDTXEasyTests/App/WorkspaceV4VisionFeatureTests.swift` |
| Easy | `AudioMixEngineUnitTestSuite` | `Tests/LDTXEasyTests/AudioEngine/AudioMixEngineTests.swift` |
| Easy | `CaptureSessionRuntimeFailurePolicyUnitTestSuite` | `Tests/LDTXEasyTests/Capture/CaptureSessionRuntimeFailurePolicyTests.swift` |
| Easy | `CaptureSessionStartupSequenceUnitTestSuite` | `Tests/LDTXEasyTests/Capture/CaptureSessionStartupSequenceTests.swift` |
| Easy | `SharedCaptureSessionPlannerUnitTestSuite` | `Tests/LDTXEasyTests/Capture/SharedCaptureSessionPlannerTests.swift` |
| Output | `DASHIngestEndpointUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHIngestEndpointTests.swift` |
| Output | `DASHLiveUploadPipelineUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHLiveUploadPipelineTests.swift` |
| Output | `DASHManifestUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHManifestTests.swift` |
| Output | `DASHUploadClientUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHUploadClientTests.swift` |
| Output | `DASHUploadFinalizationStateUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHUploadFinalizationStateTests.swift` |
| Easy | `AudioInputDeviceUnitTestSuite` | `Tests/LDTXEasyTests/DeviceRegistry/AudioInputDeviceTests.swift` |
| Easy | `LowFrequencyUpdateRegistryIntegrationTestSuite` | `Tests/LDTXEasyTests/Integration/LowFrequencyUpdateRegistryTests.swift` |
| Output | `YouTubeOutputServiceProcessClientIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/YouTubeOutputServiceProcessClientTests.swift` |
| Output | `YouTubeOutputWorkspaceServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/YouTubeOutputWorkspaceServiceTests.swift` |
| Output | `DASHStreamContinuityUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/DASHStreamContinuityTests.swift` |
| Output | `ProgramFramePacerUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramFramePacerTests.swift` |
| Output | `ProgramOutputProfileUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputProfileTests.swift` |
| Output | `SessionRecordAudioTrackUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/SessionRecordAudioTrackTests.swift` |
| Output | `YouTubeOutputMediaBacklogUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeOutputMediaBacklogTests.swift` |
| Output | `YouTubeOutputRecoveryPolicyUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeOutputRecoveryPolicyTests.swift` |
| Easy | `BackgroundTaskQueueCancellationIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/BackgroundTaskQueueCancellationTests.swift` |
| Easy | `SessionTaskQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/BackgroundTaskQueueTests.swift` |
| Easy | `EventTaskQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/EventTaskQueueTests.swift` |
| Easy | `ResourceTaskQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/ResourceTaskQueueTests.swift` |
| Easy | `WorkspaceResourceQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/WorkspaceResourceQueueTests.swift` |
| Easy | `WorkspaceAppletDataPropertyListUnitTestSuite` | `Tests/LDTXEasyTests/Workspace/WorkspaceAppletDataPropertyListTests.swift` |
| Easy | `WorkspaceResourcePathComponentCodecUnitTestSuite` | `Tests/LDTXEasyTests/Workspace/WorkspaceResourcePathComponentCodecTests.swift` |
| Easy | `YouTubeLiveAPIClientUnitTestSuite` | `Tests/LDTXEasyTests/YouTube/YouTubeLiveAPIClientTests.swift` |
| Easy | `GoogleOAuthClientConfigurationUnitTestSuite` | `Tests/LDTXEasyTests/YouTubeAuth/GoogleOAuthClientConfigurationTests.swift` |
| Output | `YouTubeOutputProtocolUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeOutputProtocol/YouTubeOutputProtocolTests.swift` |
| Output | `FLVPacketEncoderUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/FLVPacketEncoderTests.swift` |
| Output | `RTMPEncodingUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/RTMPEncodingTests.swift` |
| Output | `YouTubeRTMPSPublisherIntegrationTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/YouTubeRTMPSPublisherTests.swift` |
| Output | `YouTubeRTMPSStreamKeyConfigurationUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/YouTubeRTMPSStreamKeyConfigurationTests.swift` |
| Medium | `AudioMixRoutingUnitTestSuite` | `Tests/LDTXMediumTests/App/AudioMixRoutingTests.swift` |
| Output | `LocalOutputServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/App/LocalOutputServiceTests.swift` |
| Output | `ApplicationSettingsStoreIntegrationTestSuite` | `Tests/LDTXOutputTests/App/ApplicationOutputPreferencesTests.swift` |
| Medium | `RationalFormatStyleUnitTestSuite` | `Tests/LDTXMediumTests/App/RationalFormatStyleTests.swift` |
| Medium | `RecordingMarkerStoreIntegrationTestSuite` | `Tests/LDTXMediumTests/App/RecordingMarkerStoreTests.swift` |
| Medium | `ScreenCaptureServiceIntegrationTestSuite` | `Tests/LDTXMediumTests/App/ScreenCaptureServiceTests.swift` |
| Medium | `WorkspaceDocumentPackageIntegrationTestSuite` | `Tests/LDTXMediumTests/App/WorkspaceDocumentPackageTests.swift` |
| Medium | `WorkspaceV4PersistenceCoordinatorIntegrationTestSuite` | `Tests/LDTXMediumTests/App/WorkspaceV4PersistenceCoordinatorTests.swift` |
| Medium | `YouTubeAuthStateIntegrationTestSuite` | `Tests/LDTXMediumTests/App/YouTubeAuthStateTests.swift` |
| Output | `DASHLocalFilePipelineIntegrationTestSuite` | `Tests/LDTXOutputTests/Dash/DASHLocalFilePipelineTests.swift` |
| Medium | `DiagnosticsDatabaseIntegrationTestSuite` | `Tests/LDTXMediumTests/Diagnostics/DiagnosticsDatabaseTests.swift` |
| Medium | `EventTaskLoggerIntegrationTestSuite` | `Tests/LDTXMediumTests/Diagnostics/EventTaskLoggerTests.swift` |
| Medium | `WorkspaceCaptureSessionCoordinatorIntegrationTestSuite` | `Tests/LDTXMediumTests/Integration/WorkspaceCaptureSessionCoordinatorTests.swift` |
| Output | `YouTubeOutputMediaBatcherIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/YouTubeOutputMediaBatcherTests.swift` |
| Output | `MP4TimingBoxUnitTestSuite` | `Tests/LDTXOutputTests/MP4/MP4TimingBoxTests.swift` |
| Output | `AudioChannelTimelineUnitTestSuite` | `Tests/LDTXOutputTests/MediaTiming/AudioChannelTimelineTests.swift` |
| Output | `AudioFramePTSClockUnitTestSuite` | `Tests/LDTXOutputTests/MediaTiming/AudioFramePTSClockTests.swift` |
| Output | `DualCanvasRecordingPackageIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/DualCanvasRecordingPackageTests.swift` |
| Medium | `ProgramAudioInputPassthroughUnitTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramAudioInputPassthroughTests.swift` |
| Medium | `ProgramAudioMonitorMixerIntegrationTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramAudioMonitorMixerTests.swift` |
| Output | `ProgramOutputMediaHubIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputMediaHubTests.swift` |
| Output | `ProgramOutputSharedH264ServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputSharedH264ServiceTests.swift` |
| Output | `ProgramOutputVideoTimelineUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputVideoTimelineTests.swift` |
| Output | `ProgramVideoPTSSelectorHostClockIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramVideoPTSSelectorHostClockTests.swift` |
| Output | `ProgramVideoPTSSelectorUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramVideoPTSSelectorTests.swift` |
| Output | `RecordingTimelineNormalizerUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/RecordingTimelineNormalizerTests.swift` |
| Corelibs | `RecordingDiagnosticsEventLogIntegrationTestSuite` | `Tests/Corelibs/LDTXRecordBundleFormatTests/RecordingDiagnosticsEventLogTests.swift` |
| Corelibs | `RecordingPackageIntegrationTestSuite` | `Tests/Corelibs/LDTXRecordBundleFormatTests/RecordingPackageTests.swift` |
| Medium | `VisionFramePoolUnitTestSuite` | `Tests/LDTXMediumTests/Vision/VisionFramePoolTests.swift` |
| Medium | `GoogleOAuthLoopbackListenerIntegrationTestSuite` | `Tests/LDTXMediumTests/YouTubeAuth/GoogleOAuthLoopbackListenerTests.swift` |
| Medium | `YouTubeAuthFileIntegrationTestSuite` | `Tests/LDTXMediumTests/YouTubeAuth/YouTubeAuthFileTests.swift` |
| Medium | `YouTubeAuthorizationServiceIntegrationTestSuite` | `Tests/LDTXMediumTests/YouTubeAuth/YouTubeAuthorizationServiceKeychainTests.swift` |
| Output | `YouTubeOutputVideoFrameHoldUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeOutputProtocol/YouTubeOutputVideoFrameHoldTests.swift` |
| Hard | `WorkspaceWindowRuntimeIntegrationTestSuite` | `Tests/LDTXHardTests/App/WorkspaceWindowRuntimeTests.swift` |
| Hard | `BackgroundRemovalInferenceGateIntegrationTestSuite` | `Tests/LDTXHardTests/BackgroundSegmentation/BackgroundRemovalInferenceGateTests.swift` |
| Output | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/AVAssetWriterLifecycleIntegrationTestSuite.swift` |
| Output | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Output | `AudioSideStreamSegmentPipelineIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Output | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/H264VideoEncoderTests.swift` |
| Output | `H264VideoEncoderIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/H264VideoEncoderTests.swift` |
| Hard | `ProgramRenderingOrderIntegrationTestSuite` | `Tests/LDTXHardTests/Program/ProgramRenderingOrderTests.swift` |
| Output | `ActiveProgramOutputSessionIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ActiveProgramOutputSessionTests.swift` |
| Hard | `ClockOverlayRuntimeIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ClockOverlayRuntimeTests.swift` |
| Hard | `ManualCapturePipelineIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ManualCapturePipelineTests.swift` |
| Hard | `ProgramFrameDeliveryIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ProgramFrameDeliveryTests.swift` |
| Hard | `ProgramRuntimePreferencesUnitTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ProgramRuntimePreferencesTests.swift` |
| Hard | `VideoInputPreprocessingIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/VideoInputPreprocessingTests.swift` |
| Hard | `WorkspaceClockOCRIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/WorkspaceClockOCRTests.swift` |
| Hard | `WorkspaceVideoComponentVisionIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/WorkspaceVideoComponentVisionTests.swift` |
| Output | `YouTubeOutputMediaSampleConverterIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeOutputMediaSampleConverterTests.swift` |
| Output | `YouTubeRTMPSWorkspaceServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeRTMPSWorkspaceServiceTests.swift` |
| Hard | `ProgramPairPreviewRendererIntegrationTestSuite` | `Tests/LDTXHardTests/VideoRendering/ProgramPairPreviewRendererTests.swift` |
| Hard | `VideoCompositorIntegrationTestSuite` | `Tests/LDTXHardTests/VideoRendering/VideoCompositorTests.swift` |
| Hard | `VisionOCRConfigurationUnitTestSuite` | `Tests/LDTXHardTests/Vision/VisionOCRConfigurationTests.swift` |
| Hard | `WorkspaceProgramSwitchingIntegrationTestSuite` | `Tests/LDTXHardTests/Workspace/WorkspaceProgramSwitchingTests.swift` |

## Separate execution boundaries

Corelibs suites under `Tests/Corelibs/<module>Tests` remain in
`LDTXCorelibsTests` for XcodeGen and SwiftPM, including deterministic Unit suites
and filesystem Integration suites. SwiftPM tests are outside the tier rule.

Direct UI component and Document tests remain in `LDTXAppUIComponentTests` with
its serialized MainActor parent. Application UI automation remains in
`LDTXAppUITests`; XPC integration remains in `LDTXAppXpcTests` with its host.

| Target | Suite | Source |
| --- | --- | --- |
| `LDTXCorelibsTests` | `ProgramComponentPersistenceUnitTestSuite` | `Tests/Corelibs/LDTXProgramTests/ProgramComponentPersistenceTests.swift` |
| `LDTXCorelibsTests` | `ProgramPreferencesUnitTestSuite` | `Tests/Corelibs/LDTXProgramTests/ProgramPreferencesTests.swift` |
| `LDTXCorelibsTests` | `Rational32UnitTestSuite` | `Tests/Corelibs/LDTXProtosTests/Rational32Tests.swift` |
| `LDTXCorelibsTests` | `WorkspaceV4IntegrityValidatorUnitTestSuite` | `Tests/Corelibs/LDTXProtosTests/WorkspaceV4IntegrityValidatorTests.swift` |
| `LDTXCorelibsTests` | `WorkspaceBundleFormatIntegrationTestSuite` | `Tests/Corelibs/LDTXWorkspaceBundleFormatTests/WorkspaceBundleFormatTests.swift` |

Output suites share the serialized `OutputTestSuite` parent to coordinate
media-session startup and callbacks while preserving individual Unit and
Integration suite names. This remains a hostless unit-test target.
