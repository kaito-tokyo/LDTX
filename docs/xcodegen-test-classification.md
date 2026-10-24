<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# XcodeGen test classification inventory

`AGENTS.md` is the source of truth. Classify the APIs exercised by each test and
its SUT, rather than imports, computational cost, permissions, or CI availability.
Unit and Integration scope is independent of the Easy, Medium, and Hard tiers.
These tiers are suite tags in the shared `LDTXModuleTests` target, selected by
the `Easy`, `Medium`, and `Hard` test plans.
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
| Easy | `ApplicationTerminationCoordinatorIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXAppletSupport/ApplicationTerminationCoordinatorTests.swift` |
| Output | `OutputSettingsModelUnitTestSuite` | `Tests/LDTXOutputTests/App/OutputSettingsModelTests.swift` |
| Easy | `ProgramLibraryUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/ProgramLibraryTests.swift` |
| Easy | `ProgramPairPreviewRegionsUnitTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/ProgramPairPreviewRegionsTests.swift` |
| Easy | `ProgramPreferencesStoreUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletStore/ProgramPreferencesStoreTests.swift` |
| Easy | `ProgramRuntimeStateUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/ProgramRuntimeStateTests.swift` |
| Easy | `WorkspaceSelectionUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletUI/WorkspaceSelectionTests.swift` |
| Easy | `WorkspaceShutdownCoordinatorIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceShutdownCoordinatorTests.swift` |
| Easy | `WorkspaceV4RenderGraphUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceV4RenderGraphTests.swift` |
| Easy | `WorkspaceV4VisionFeatureUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceV4VisionFeatureTests.swift` |
| Easy | `CaptureSessionRuntimeFailurePolicyUnitTestSuite` | `Tests/LDTXModuleTests/LDTXCapture/CaptureSessionRuntimeFailurePolicyTests.swift` |
| Output | `DASHIngestEndpointUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHIngestEndpointTests.swift` |
| Output | `DASHLiveUploadPipelineUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHLiveUploadPipelineTests.swift` |
| Output | `DASHManifestUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHManifestTests.swift` |
| Output | `DASHUploadClientUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHUploadClientTests.swift` |
| Output | `DASHUploadFinalizationStateUnitTestSuite` | `Tests/LDTXOutputTests/Dash/DASHUploadFinalizationStateTests.swift` |
| Easy | `AudioInputDeviceUnitTestSuite` | `Tests/LDTXModuleTests/LDTXDeviceRegistry/AudioInputDeviceTests.swift` |
| Output | `YouTubeOutputServiceProcessClientIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/YouTubeOutputServiceProcessClientTests.swift` |
| Output | `YouTubeOutputWorkspaceServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/YouTubeOutputWorkspaceServiceTests.swift` |
| Output | `DASHStreamContinuityUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/DASHStreamContinuityTests.swift` |
| Output | `ProgramFramePacerUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramFramePacerTests.swift` |
| Output | `SessionRecordAudioTrackUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/SessionRecordAudioTrackTests.swift` |
| Output | `YouTubeOutputMediaBacklogUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeOutputMediaBacklogTests.swift` |
| Output | `YouTubeOutputRecoveryPolicyUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeOutputRecoveryPolicyTests.swift` |
| Easy | `BackgroundTaskQueueCancellationIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXTaskQueue/BackgroundTaskQueueCancellationTests.swift` |
| Easy | `SessionTaskQueueIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXTaskQueue/BackgroundTaskQueueTests.swift` |
| Easy | `EventTaskQueueIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXTaskQueue/EventTaskQueueTests.swift` |
| Easy | `ResourceTaskQueueIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXTaskQueue/ResourceTaskQueueTests.swift` |
| Easy | `WorkspaceResourceQueueIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXTaskQueue/WorkspaceResourceQueueTests.swift` |
| Easy | `WorkspaceAppletDataPropertyListUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletUI/WorkspaceAppletDataPropertyListTests.swift` |
| Easy | `WorkspaceResourcePathComponentCodecUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceResourcePathComponentCodecTests.swift` |
| Easy | `YouTubeLiveAPIClientUnitTestSuite` | `Tests/LDTXModuleTests/LDTXYouTube/YouTubeLiveAPIClientTests.swift` |
| Easy | `GoogleOAuthClientConfigurationUnitTestSuite` | `Tests/LDTXModuleTests/LDTXYouTubeAuth/GoogleOAuthClientConfigurationTests.swift` |
| Output | `YouTubeOutputProtocolUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeOutputProtocol/YouTubeOutputProtocolTests.swift` |
| Output | `FLVPacketEncoderUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/FLVPacketEncoderTests.swift` |
| Output | `RTMPEncodingUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/RTMPEncodingTests.swift` |
| Output | `YouTubeRTMPSPublisherIntegrationTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/YouTubeRTMPSPublisherTests.swift` |
| Output | `YouTubeRTMPSStreamKeyConfigurationUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeRTMPS/YouTubeRTMPSStreamKeyConfigurationTests.swift` |
| Medium | `AudioMixRoutingUnitTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/AudioMixRoutingTests.swift` |
| Output | `LocalOutputServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/App/LocalOutputServiceTests.swift` |
| Output | `ApplicationSettingsStoreIntegrationTestSuite` | `Tests/LDTXOutputTests/App/ApplicationOutputPreferencesTests.swift` |
| Medium | `RationalFormatStyleUnitTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletUI/RationalFormatStyleTests.swift` |
| Medium | `RecordingMarkerStoreIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXRecordPlayerApplet/RecordingMarkerStoreTests.swift` |
| Medium | `ScreenCaptureServiceIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/ScreenCaptureServiceTests.swift` |
| Medium | `WorkspaceV4PersistenceCoordinatorIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceV4PersistenceCoordinatorTests.swift` |
| Medium | `YouTubeAuthStateIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXSettingsApplet/YouTubeAuthStateTests.swift` |
| Output | `DASHLocalFilePipelineIntegrationTestSuite` | `Tests/LDTXOutputTests/Dash/DASHLocalFilePipelineTests.swift` |
| Medium | `WorkspaceCaptureSessionCoordinatorIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/WorkspaceCaptureSessionCoordinatorTests.swift` |
| Output | `YouTubeOutputMediaBatcherIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/YouTubeOutputMediaBatcherTests.swift` |
| Output | `MP4TimingBoxUnitTestSuite` | `Tests/LDTXOutputTests/MP4/MP4TimingBoxTests.swift` |
| Output | `AudioChannelTimelineUnitTestSuite` | `Tests/LDTXOutputTests/MediaTiming/AudioChannelTimelineTests.swift` |
| Output | `AudioFramePTSClockUnitTestSuite` | `Tests/LDTXOutputTests/MediaTiming/AudioFramePTSClockTests.swift` |
| Output | `DualCanvasRecordingPackageIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/DualCanvasRecordingPackageTests.swift` |
| Medium | `ProgramAudioMonitorMixerIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/ProgramAudioMonitorMixerTests.swift` |
| Output | `ProgramOutputMediaHubIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputMediaHubTests.swift` |
| Output | `ProgramOutputSharedH264ServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputSharedH264ServiceTests.swift` |
| Output | `ProgramOutputVideoTimelineUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramOutputVideoTimelineTests.swift` |
| Output | `ProgramVideoPTSSelectorHostClockIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramVideoPTSSelectorHostClockTests.swift` |
| Output | `ProgramVideoPTSSelectorUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ProgramVideoPTSSelectorTests.swift` |
| Output | `RecordingTimelineNormalizerUnitTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/RecordingTimelineNormalizerTests.swift` |
| Corelibs | `RecordingPackageIntegrationTestSuite` | `Tests/Corelibs/LDTXRecordBundleFormatTests/RecordingPackageTests.swift` |
| Medium | `VisionFramePoolUnitTestSuite` | `Tests/LDTXModuleTests/LDTXVision/VisionFramePoolTests.swift` |
| Medium | `YouTubeAuthFileIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXYouTubeAuth/YouTubeAuthFileTests.swift` |
| Medium | `YouTubeAuthorizationServiceIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXYouTubeAuth/YouTubeAuthorizationServiceKeychainTests.swift` |
| Output | `YouTubeOutputVideoFrameHoldUnitTestSuite` | `Tests/LDTXOutputTests/YouTubeOutputProtocol/YouTubeOutputVideoFrameHoldTests.swift` |
| Hard | `WorkspaceWindowRuntimeIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceWindowRuntimeTests.swift` |
| Hard | `BackgroundRemovalInferenceGateIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXBackgroundSegmentation/BackgroundRemovalInferenceGateTests.swift` |
| Output | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/AVAssetWriterLifecycleIntegrationTestSuite.swift` |
| Output | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Output | `AudioSideStreamSegmentPipelineIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/AudioSideStreamSegmentPipelineTests.swift` |
| Output | `AVAssetWriterLifecycleIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/H264VideoEncoderTests.swift` |
| Output | `H264VideoEncoderIntegrationTestSuite` | `Tests/LDTXOutputTests/Integration/H264VideoEncoderTests.swift` |
| Hard | `ProgramRenderingOrderIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRendering/ProgramRenderingOrderTests.swift` |
| Output | `ActiveProgramOutputSessionIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/ActiveProgramOutputSessionTests.swift` |
| Hard | `ClockOverlayRuntimeIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/ClockOverlayRuntimeTests.swift` |
| Hard | `ManualCapturePipelineIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/ManualCapturePipelineTests.swift` |
| Hard | `ProgramFrameDeliveryIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/ProgramFrameDeliveryTests.swift` |
| Hard | `ProgramRuntimePreferencesUnitTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/ProgramRuntimePreferencesTests.swift` |
| Hard | `VideoInputPreprocessingIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXProgramRuntime/VideoInputPreprocessingTests.swift` |
| Hard | `WorkspaceClockOCRIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceClockOCRTests.swift` |
| Hard | `WorkspaceVideoComponentVisionIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceVideoComponentVisionTests.swift` |
| Output | `YouTubeOutputMediaSampleConverterIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeOutputMediaSampleConverterTests.swift` |
| Output | `YouTubeRTMPSWorkspaceServiceIntegrationTestSuite` | `Tests/LDTXOutputTests/ProgramRuntime/YouTubeRTMPSWorkspaceServiceTests.swift` |
| Hard | `ProgramPairPreviewRendererIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXVideoRendering/ProgramPairPreviewRendererTests.swift` |
| Hard | `VideoCompositorIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXVideoRendering/VideoCompositorTests.swift` |
| Hard | `VisionOCRConfigurationUnitTestSuite` | `Tests/LDTXModuleTests/LDTXVision/VisionOCRConfigurationTests.swift` |
| Hard | `WorkspaceProgramSwitchingIntegrationTestSuite` | `Tests/LDTXModuleTests/LDTXWorkspaceAppletService/WorkspaceProgramSwitchingTests.swift` |

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
| `LDTXCorelibsTests` | `WorkspaceBundleValidatorV4UnitTestSuite` | `Tests/Corelibs/LDTXWorkspaceBundleFormatTests/WorkspaceBundleValidatorTests.swift` |
| `LDTXCorelibsTests` | `WorkspaceV4DiagnosticsIntegrationTestSuite` | `Tests/Corelibs/LDTXWorkspaceBundleFormatTests/WorkspaceV4DiagnosticsTests.swift` |
| `LDTXCorelibsTests` | `WorkspaceBundleFormatIntegrationTestSuite` | `Tests/Corelibs/LDTXWorkspaceBundleFormatTests/WorkspaceBundleFormatTests.swift` |

Output suites share the serialized `OutputTestSuite` parent to coordinate
media-session startup and callbacks while preserving individual Unit and
Integration suite names. This remains a hostless unit-test target.
