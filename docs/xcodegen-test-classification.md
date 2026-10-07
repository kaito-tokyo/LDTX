<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# XcodeGen test classification inventory

`AGENTS.md` is the source of truth. Classify the APIs exercised by each test and
its SUT, rather than imports, computational cost, permissions, or CI availability.
Unit and Integration scope is independent of the Easy, Medium, and Hard tiers.

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

The AVAssetWriter lifecycle parent and its extensions remain together in Hard
with their serialized execution control. Serialization does not create a
SystemTests isolation boundary.

All three tier targets are hostless. Xcode Cloud runs `LDTXHardTests` directly
using the `XcodeCloud` plan. Only `LDTXAppUITests` uses XCUI, and only XpcTests may
use an application host. UI component and Corelibs target boundaries are unchanged.

## Tier suite inventory

Paths are relative to the repository root. The listed tier includes dependencies
exercised through the SUT, even when they do not appear as imports in the test.

| Tier | Suite | Source |
| --- | --- | --- |
| Easy | `ApplicationTerminationCoordinatorIntegrationTestSuite` | `Tests/LDTXEasyTests/App/ApplicationTerminationCoordinatorTests.swift` |
| Easy | `OutputSettingsModelUnitTestSuite` | `Tests/LDTXEasyTests/App/OutputSettingsModelTests.swift` |
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
| Easy | `DASHIngestEndpointUnitTestSuite` | `Tests/LDTXEasyTests/Dash/DASHIngestEndpointTests.swift` |
| Easy | `DASHLiveUploadPipelineUnitTestSuite` | `Tests/LDTXEasyTests/Dash/DASHLiveUploadPipelineTests.swift` |
| Easy | `DASHManifestUnitTestSuite` | `Tests/LDTXEasyTests/Dash/DASHManifestTests.swift` |
| Easy | `DASHUploadClientUnitTestSuite` | `Tests/LDTXEasyTests/Dash/DASHUploadClientTests.swift` |
| Easy | `DASHUploadFinalizationStateUnitTestSuite` | `Tests/LDTXEasyTests/Dash/DASHUploadFinalizationStateTests.swift` |
| Easy | `AudioInputDeviceUnitTestSuite` | `Tests/LDTXEasyTests/DeviceRegistry/AudioInputDeviceTests.swift` |
| Easy | `LowFrequencyUpdateRegistryIntegrationTestSuite` | `Tests/LDTXEasyTests/Integration/LowFrequencyUpdateRegistryTests.swift` |
| Easy | `YouTubeOutputServiceProcessClientIntegrationTestSuite` | `Tests/LDTXEasyTests/Integration/YouTubeOutputServiceProcessClientTests.swift` |
| Easy | `YouTubeOutputWorkspaceServiceIntegrationTestSuite` | `Tests/LDTXEasyTests/Integration/YouTubeOutputWorkspaceServiceTests.swift` |
| Easy | `DASHStreamContinuityUnitTestSuite` | `Tests/LDTXEasyTests/ProgramRuntime/DASHStreamContinuityTests.swift` |
| Easy | `ProgramFramePacerUnitTestSuite` | `Tests/LDTXEasyTests/ProgramRuntime/ProgramFramePacerTests.swift` |
| Easy | `ProgramOutputProfileUnitTestSuite` | `Tests/LDTXEasyTests/ProgramRuntime/ProgramOutputProfileTests.swift` |
| Easy | `SessionRecordAudioTrackUnitTestSuite` | `Tests/LDTXEasyTests/ProgramRuntime/SessionRecordAudioTrackTests.swift` |
| Easy | `YouTubeOutputMediaBacklogUnitTestSuite` | `Tests/LDTXEasyTests/ProgramRuntime/YouTubeOutputMediaBacklogTests.swift` |
| Easy | `YouTubeOutputRecoveryPolicyUnitTestSuite` | `Tests/LDTXEasyTests/ProgramRuntime/YouTubeOutputRecoveryPolicyTests.swift` |
| Easy | `BackgroundTaskQueueCancellationIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/BackgroundTaskQueueCancellationTests.swift` |
| Easy | `SessionTaskQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/BackgroundTaskQueueTests.swift` |
| Easy | `EventTaskQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/EventTaskQueueTests.swift` |
| Easy | `ResourceTaskQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/ResourceTaskQueueTests.swift` |
| Easy | `WorkspaceResourceQueueIntegrationTestSuite` | `Tests/LDTXEasyTests/TaskQueue/WorkspaceResourceQueueTests.swift` |
| Easy | `WorkspaceAppletDataPropertyListUnitTestSuite` | `Tests/LDTXEasyTests/Workspace/WorkspaceAppletDataPropertyListTests.swift` |
| Easy | `WorkspaceResourcePathComponentCodecUnitTestSuite` | `Tests/LDTXEasyTests/Workspace/WorkspaceResourcePathComponentCodecTests.swift` |
| Easy | `YouTubeLiveAPIClientUnitTestSuite` | `Tests/LDTXEasyTests/YouTube/YouTubeLiveAPIClientTests.swift` |
| Easy | `GoogleOAuthClientConfigurationUnitTestSuite` | `Tests/LDTXEasyTests/YouTubeAuth/GoogleOAuthClientConfigurationTests.swift` |
| Easy | `YouTubeOutputProtocolUnitTestSuite` | `Tests/LDTXEasyTests/YouTubeOutputProtocol/YouTubeOutputProtocolTests.swift` |
| Easy | `FLVPacketEncoderUnitTestSuite` | `Tests/LDTXEasyTests/YouTubeRTMPS/FLVPacketEncoderTests.swift` |
| Easy | `RTMPEncodingUnitTestSuite` | `Tests/LDTXEasyTests/YouTubeRTMPS/RTMPEncodingTests.swift` |
| Easy | `YouTubeRTMPSPublisherIntegrationTestSuite` | `Tests/LDTXEasyTests/YouTubeRTMPS/YouTubeRTMPSPublisherTests.swift` |
| Easy | `YouTubeRTMPSStreamKeyConfigurationUnitTestSuite` | `Tests/LDTXEasyTests/YouTubeRTMPS/YouTubeRTMPSStreamKeyConfigurationTests.swift` |
| Medium | `AudioMixRoutingUnitTestSuite` | `Tests/LDTXMediumTests/App/AudioMixRoutingTests.swift` |
| Medium | `LocalOutputServiceIntegrationTestSuite` | `Tests/LDTXMediumTests/App/LocalOutputServiceTests.swift` |
| Medium | `ApplicationSettingsStoreIntegrationTestSuite` | `Tests/LDTXMediumTests/App/OutputSettingsModelTests.swift` |
| Medium | `RationalFormatStyleUnitTestSuite` | `Tests/LDTXMediumTests/App/RationalFormatStyleTests.swift` |
| Medium | `RecordingMarkerStoreIntegrationTestSuite` | `Tests/LDTXMediumTests/App/RecordingMarkerStoreTests.swift` |
| Medium | `ScreenCaptureServiceIntegrationTestSuite` | `Tests/LDTXMediumTests/App/ScreenCaptureServiceTests.swift` |
| Medium | `WorkspaceDocumentPackageIntegrationTestSuite` | `Tests/LDTXMediumTests/App/WorkspaceDocumentPackageTests.swift` |
| Medium | `WorkspaceV4PersistenceCoordinatorIntegrationTestSuite` | `Tests/LDTXMediumTests/App/WorkspaceV4PersistenceCoordinatorTests.swift` |
| Medium | `YouTubeAuthStateIntegrationTestSuite` | `Tests/LDTXMediumTests/App/YouTubeAuthStateTests.swift` |
| Medium | `DASHLocalFilePipelineIntegrationTestSuite` | `Tests/LDTXMediumTests/Dash/DASHLocalFilePipelineTests.swift` |
| Medium | `DiagnosticsDatabaseIntegrationTestSuite` | `Tests/LDTXMediumTests/Diagnostics/DiagnosticsDatabaseTests.swift` |
| Medium | `EventTaskLoggerIntegrationTestSuite` | `Tests/LDTXMediumTests/Diagnostics/EventTaskLoggerTests.swift` |
| Medium | `WorkspaceCaptureSessionCoordinatorIntegrationTestSuite` | `Tests/LDTXMediumTests/Integration/WorkspaceCaptureSessionCoordinatorTests.swift` |
| Medium | `YouTubeOutputMediaBatcherIntegrationTestSuite` | `Tests/LDTXMediumTests/Integration/YouTubeOutputMediaBatcherTests.swift` |
| Medium | `MP4TimingBoxUnitTestSuite` | `Tests/LDTXMediumTests/MP4/MP4TimingBoxTests.swift` |
| Medium | `AudioChannelTimelineUnitTestSuite` | `Tests/LDTXMediumTests/MediaTiming/AudioChannelTimelineTests.swift` |
| Medium | `AudioFramePTSClockUnitTestSuite` | `Tests/LDTXMediumTests/MediaTiming/AudioFramePTSClockTests.swift` |
| Medium | `DualCanvasRecordingPackageIntegrationTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/DualCanvasRecordingPackageTests.swift` |
| Medium | `ProgramAudioInputPassthroughUnitTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramAudioInputPassthroughTests.swift` |
| Medium | `ProgramAudioMonitorMixerIntegrationTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramAudioMonitorMixerTests.swift` |
| Medium | `ProgramOutputMediaHubIntegrationTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramOutputMediaHubTests.swift` |
| Medium | `ProgramOutputSharedH264ServiceIntegrationTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramOutputSharedH264ServiceTests.swift` |
| Medium | `ProgramOutputVideoTimelineUnitTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramOutputVideoTimelineTests.swift` |
| Medium | `ProgramVideoPTSSelectorHostClockIntegrationTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramVideoPTSSelectorHostClockTests.swift` |
| Medium | `ProgramVideoPTSSelectorUnitTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/ProgramVideoPTSSelectorTests.swift` |
| Medium | `RecordingTimelineNormalizerUnitTestSuite` | `Tests/LDTXMediumTests/ProgramRuntime/RecordingTimelineNormalizerTests.swift` |
| Medium | `RecordingDiagnosticsEventLogIntegrationTestSuite` | `Tests/LDTXMediumTests/Recording/RecordingDiagnosticsEventLogTests.swift` |
| Medium | `RecordingPackageIntegrationTestSuite` | `Tests/LDTXMediumTests/Recording/RecordingPackageTests.swift` |
| Medium | `RecordingShieldIntegrationTestSuite` | `Tests/LDTXMediumTests/Recording/RecordingShieldTests.swift` |
| Medium | `VisionFramePoolUnitTestSuite` | `Tests/LDTXMediumTests/Vision/VisionFramePoolTests.swift` |
| Medium | `GoogleOAuthLoopbackListenerIntegrationTestSuite` | `Tests/LDTXMediumTests/YouTubeAuth/GoogleOAuthLoopbackListenerTests.swift` |
| Medium | `YouTubeAuthFileIntegrationTestSuite` | `Tests/LDTXMediumTests/YouTubeAuth/YouTubeAuthFileTests.swift` |
| Medium | `YouTubeAuthorizationServiceIntegrationTestSuite` | `Tests/LDTXMediumTests/YouTubeAuth/YouTubeAuthorizationServiceKeychainTests.swift` |
| Medium | `YouTubeOutputVideoFrameHoldUnitTestSuite` | `Tests/LDTXMediumTests/YouTubeOutputProtocol/YouTubeOutputVideoFrameHoldTests.swift` |
| Hard | `WorkspaceWindowRuntimeIntegrationTestSuite` | `Tests/LDTXHardTests/App/WorkspaceWindowRuntimeTests.swift` |
| Hard | `BackgroundRemovalInferenceGateIntegrationTestSuite` | `Tests/LDTXHardTests/BackgroundSegmentation/BackgroundRemovalInferenceGateTests.swift` |
| Hard | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXHardTests/Integration/AVAssetWriterLifecycleIntegrationTestSuite.swift` |
| Hard | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXHardTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Hard | `AudioSideStreamSegmentPipelineIntegrationTestSuite` | `Tests/LDTXHardTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Hard | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXHardTests/Integration/H264VideoEncoderTests.swift` |
| Hard | `H264VideoEncoderIntegrationTestSuite` | `Tests/LDTXHardTests/Integration/H264VideoEncoderTests.swift` |
| Hard | `ProgramRenderingOrderIntegrationTestSuite` | `Tests/LDTXHardTests/Program/ProgramRenderingOrderTests.swift` |
| Hard | `ActiveProgramOutputSessionIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ActiveProgramOutputSessionTests.swift` |
| Hard | `ClockOverlayRuntimeIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ClockOverlayRuntimeTests.swift` |
| Hard | `ManualCapturePipelineIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ManualCapturePipelineTests.swift` |
| Hard | `ProgramFrameDeliveryIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ProgramFrameDeliveryTests.swift` |
| Hard | `ProgramRuntimePreferencesUnitTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/ProgramRuntimePreferencesTests.swift` |
| Hard | `VideoInputPreprocessingIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/VideoInputPreprocessingTests.swift` |
| Hard | `WorkspaceClockOCRIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/WorkspaceClockOCRTests.swift` |
| Hard | `WorkspaceVideoComponentVisionIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/WorkspaceVideoComponentVisionTests.swift` |
| Hard | `YouTubeOutputMediaSampleConverterIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/YouTubeOutputMediaSampleConverterTests.swift` |
| Hard | `YouTubeRTMPSWorkspaceServiceIntegrationTestSuite` | `Tests/LDTXHardTests/ProgramRuntime/YouTubeRTMPSWorkspaceServiceTests.swift` |
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
