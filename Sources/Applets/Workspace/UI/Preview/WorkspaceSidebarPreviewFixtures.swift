// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
  import LDTXWorkspaceAppletInterface

  @MainActor
  enum WorkspaceSidebarPreviewFixtures {
    static func makeUIState(
      inspectorSelector: WorkspaceInspectorSelector? = nil,
      isOutputActive: Bool = false
    ) -> WorkspaceStoreService {
      WorkspaceStoreService(
        definition: makeWorkspaceDefinition(),
        preferences: .init(),
        inspectorSelector: inspectorSelector,
        isOutputActive: isOutputActive)
    }

    private static func makeWorkspaceDefinition() -> Ldtx_Workspace_V4_WorkspaceDefinitionV4 {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.displayName = "Workspace Sidebar Preview"

      var audioDevice = Ldtx_Workspace_V4_AudioInputDevice()
      audioDevice.internalID = 2
      audioDevice.displayName = "USB Microphone"
      definition.audioDevices = [audioDevice]

      var vfxSource = Ldtx_Workspace_V4_VfxSourceComponent()
      vfxSource.internalID = 3
      vfxSource.displayName = "Camera Source"
      var vfxSourceWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      vfxSourceWrapper.vfxSource = vfxSource

      var solidColorFill = Ldtx_Workspace_V4_FillSolidColorComponent()
      solidColorFill.internalID = 4
      solidColorFill.displayName = "Background"
      solidColorFill.color.red = 95.0 / 255.0
      solidColorFill.color.green = 178.0 / 255.0
      solidColorFill.color.blue = 203.0 / 255.0
      solidColorFill.color.alpha = 1
      var solidColorWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      solidColorWrapper.solidColorFill = solidColorFill

      var linearGradientFill = Ldtx_Workspace_V4_FillLinearGradientComponent()
      linearGradientFill.internalID = 5
      linearGradientFill.displayName = "Studio Gradient"
      linearGradientFill.startXRational = .with {
        $0.numerator = 0
        $0.denominator = 1
      }
      linearGradientFill.startYRational = .with {
        $0.numerator = 0
        $0.denominator = 1
      }
      linearGradientFill.endXRational = .with {
        $0.numerator = 1
        $0.denominator = 1
      }
      linearGradientFill.endYRational = .with {
        $0.numerator = 1
        $0.denominator = 1
      }
      linearGradientFill.startColor.red = 95.0 / 255.0
      linearGradientFill.startColor.green = 178.0 / 255.0
      linearGradientFill.startColor.blue = 203.0 / 255.0
      linearGradientFill.startColor.alpha = 1
      linearGradientFill.endColor.red = 1
      linearGradientFill.endColor.green = 1
      linearGradientFill.endColor.blue = 1
      linearGradientFill.endColor.alpha = 1
      var linearGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      linearGradientWrapper.linearGradientFill = linearGradientFill

      var radialGradientFill = Ldtx_Workspace_V4_FillRadialGradientComponent()
      radialGradientFill.internalID = 6
      radialGradientFill.displayName = "Radial Highlight"
      radialGradientFill.centerXRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      radialGradientFill.centerYRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      radialGradientFill.innerRadiusRational = .with {
        $0.numerator = 0
        $0.denominator = 1
      }
      radialGradientFill.outerRadiusRational = .with {
        $0.numerator = 18
        $0.denominator = 25
      }
      radialGradientFill.innerColor.red = 95.0 / 255.0
      radialGradientFill.innerColor.green = 178.0 / 255.0
      radialGradientFill.innerColor.blue = 203.0 / 255.0
      radialGradientFill.innerColor.alpha = 1
      radialGradientFill.outerColor.red = 1
      radialGradientFill.outerColor.green = 1
      radialGradientFill.outerColor.blue = 1
      radialGradientFill.outerColor.alpha = 1
      var radialGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      radialGradientWrapper.radialGradientFill = radialGradientFill

      var conicGradientFill = Ldtx_Workspace_V4_FillConicGradientComponent()
      conicGradientFill.internalID = 7
      conicGradientFill.displayName = "Color Wheel"
      conicGradientFill.centerXRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      conicGradientFill.centerYRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      conicGradientFill.startAngleRadiansRational = .with {
        $0.numerator = 0
        $0.denominator = 1
      }
      conicGradientFill.startColor.red = 95.0 / 255.0
      conicGradientFill.startColor.green = 178.0 / 255.0
      conicGradientFill.startColor.blue = 203.0 / 255.0
      conicGradientFill.startColor.alpha = 1
      conicGradientFill.endColor.red = 1
      conicGradientFill.endColor.green = 1
      conicGradientFill.endColor.blue = 1
      conicGradientFill.endColor.alpha = 1
      var conicGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      conicGradientWrapper.conicGradientFill = conicGradientFill

      var clock = Ldtx_Workspace_V4_ClockComponent()
      clock.internalID = 8
      clock.displayName = "On Air Clock"
      clock.widthRational = .with {
        $0.numerator = 1
        $0.denominator = 6
      }
      clock.heightRational = .with {
        $0.numerator = 2
        $0.denominator = 27
      }
      var clockWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      clockWrapper.clock = clock

      var testPattern = Ldtx_Workspace_V4_TestPatternComponent()
      testPattern.internalID = 9
      testPattern.displayName = "Color Bars"
      var testPatternWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      testPatternWrapper.testPattern = testPattern
      definition.videoComponents = [
        vfxSourceWrapper, solidColorWrapper, linearGradientWrapper, radialGradientWrapper,
        conicGradientWrapper, clockWrapper, testPatternWrapper,
      ]

      var intervalTrigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
      intervalTrigger.intervalSecondsRational = .with {
        $0.numerator = 5
        $0.denominator = 1
      }
      var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
      triggerWrapper.intervalTrigger = intervalTrigger
      var ocrVision = Ldtx_Workspace_V4_OcrVision()
      ocrVision.internalID = 10
      ocrVision.displayName = "Program Text OCR"
      ocrVision.videoComponentInternalID = vfxSource.internalID
      ocrVision.source = .videoComponentInternalID(vfxSource.internalID)
      ocrVision.triggers = [triggerWrapper]
      var ocrVisionWrapper = Ldtx_Workspace_V4_VisionWrapper()
      ocrVisionWrapper.ocrVision = ocrVision
      definition.visions = [ocrVisionWrapper]

      return definition
    }

  }
#endif
