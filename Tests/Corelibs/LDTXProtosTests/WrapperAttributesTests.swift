// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Testing

@Suite
struct WrapperAttributesUnitTestSuite {
  @Test func unspecifiedIngestUsesOnlyLandscapeRTMPS() {
    let mode = Ldtx_Workspace_V4_WorkspaceOutputSettingsV4().youtubeSettings.ingestMode
    #expect(mode.usesLandscapeRTMPS)
    #expect(!mode.usesPortraitRTMPS)
  }

  @Test func preservesPresenceForEveryVideoComponentKind() {
    let definitions: [Ldtx_Workspace_V4_VideoComponentWrapper.OneOf_VideoComponent] = [
      .solidColorFill(.init()), .linearGradientFill(.init()),
      .radialGradientFill(.init()), .conicGradientFill(.init()),
      .vfxSource(.init()), .clock(.init()), .testPattern(.init()),
      .solidColorFill(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
      .linearGradientFill(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
      .radialGradientFill(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
      .conicGradientFill(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
      .vfxSource(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
      .clock(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
      .testPattern(
        .with {
          $0.internalID = 0
          $0.displayName = ""
        }),
    ]
    let empty = Ldtx_Workspace_V4_VideoComponentWrapper()
    #expect(empty.internalID == nil)
    #expect(empty.displayName == nil)
    for (index, value) in definitions.enumerated() {
      var wrapper = empty
      wrapper.videoComponent = value
      #expect(wrapper.internalID == (index < 7 ? nil : 0))
      #expect(wrapper.displayName == (index < 7 ? nil : ""))
    }
  }

  @Test func readsValuesAndPreservesIndependentFieldPresence() {
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .clock(.with { $0.internalID = 42 })
    #expect(wrapper.internalID == 42)
    #expect(wrapper.displayName == nil)
    wrapper.videoComponent = .clock(.with { $0.displayName = "Clock" })
    #expect(wrapper.internalID == nil)
    #expect(wrapper.displayName == "Clock")
  }

  @Test func preservesVisionPresence() {
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    #expect(wrapper.internalID == nil)
    #expect(wrapper.displayName == nil)
    wrapper.vision = .ocrVision(.init())
    #expect(wrapper.internalID == nil)
    #expect(wrapper.displayName == nil)
    wrapper.vision = .ocrVision(
      .with {
        $0.internalID = 0
        $0.displayName = ""
      })
    #expect(wrapper.internalID == 0)
    #expect(wrapper.displayName == "")
    wrapper.vision = .ocrVision(
      .with {
        $0.internalID = 42
        $0.displayName = "OCR"
      })
    #expect(wrapper.internalID == 42)
    #expect(wrapper.displayName == "OCR")
  }
  @Test func identityDoesNotSubstituteZeroForAnUnsetID() {
    var video = Ldtx_Workspace_V4_VideoComponentWrapper()
    video.videoComponent = .clock(.init())
    #expect(video.id == .invalid)
    video.videoComponent = .clock(.with { $0.internalID = 0 })
    #expect(video.id == .clock(0))
    var vision = Ldtx_Workspace_V4_VisionWrapper()
    vision.vision = .ocrVision(.init())
    #expect(vision.id == .invalid)
    vision.vision = .ocrVision(.with { $0.internalID = 0 })
    #expect(vision.id == .ocrVision(0))
  }

}
