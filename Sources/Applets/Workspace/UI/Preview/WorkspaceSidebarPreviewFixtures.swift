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
      solidColorFill.extendedSrgbColor.red = 95.0 / 255.0
      solidColorFill.extendedSrgbColor.green = 178.0 / 255.0
      solidColorFill.extendedSrgbColor.blue = 203.0 / 255.0
      solidColorFill.extendedSrgbColor.alpha = 1
      var solidColorWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      solidColorWrapper.solidColorFill = solidColorFill

      var linearGradientFill = Ldtx_Workspace_V4_FillLinearGradientComponent()
      linearGradientFill.internalID = 5
      linearGradientFill.displayName = "Studio Gradient"
      linearGradientFill.startX = .with {
        $0.set(num: 0, den: 1)
      }
      linearGradientFill.startY = .with {
        $0.set(num: 0, den: 1)
      }
      linearGradientFill.endX = .with {
        $0.set(num: 1, den: 1)
      }
      linearGradientFill.endY = .with {
        $0.set(num: 1, den: 1)
      }
      linearGradientFill.startExtendedSrgbColor.red = 95.0 / 255.0
      linearGradientFill.startExtendedSrgbColor.green = 178.0 / 255.0
      linearGradientFill.startExtendedSrgbColor.blue = 203.0 / 255.0
      linearGradientFill.startExtendedSrgbColor.alpha = 1
      linearGradientFill.endExtendedSrgbColor.red = 1
      linearGradientFill.endExtendedSrgbColor.green = 1
      linearGradientFill.endExtendedSrgbColor.blue = 1
      linearGradientFill.endExtendedSrgbColor.alpha = 1
      var linearGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      linearGradientWrapper.linearGradientFill = linearGradientFill

      var radialGradientFill = Ldtx_Workspace_V4_FillRadialGradientComponent()
      radialGradientFill.internalID = 6
      radialGradientFill.displayName = "Radial Highlight"
      radialGradientFill.centerX = .with {
        $0.set(num: 1, den: 2)
      }
      radialGradientFill.centerY = .with {
        $0.set(num: 1, den: 2)
      }
      radialGradientFill.innerRadius = .with {
        $0.set(num: 0, den: 1)
      }
      radialGradientFill.outerRadius = .with {
        $0.set(num: 18, den: 25)
      }
      radialGradientFill.innerExtendedSrgbColor.red = 95.0 / 255.0
      radialGradientFill.innerExtendedSrgbColor.green = 178.0 / 255.0
      radialGradientFill.innerExtendedSrgbColor.blue = 203.0 / 255.0
      radialGradientFill.innerExtendedSrgbColor.alpha = 1
      radialGradientFill.outerExtendedSrgbColor.red = 1
      radialGradientFill.outerExtendedSrgbColor.green = 1
      radialGradientFill.outerExtendedSrgbColor.blue = 1
      radialGradientFill.outerExtendedSrgbColor.alpha = 1
      var radialGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      radialGradientWrapper.radialGradientFill = radialGradientFill

      var conicGradientFill = Ldtx_Workspace_V4_FillConicGradientComponent()
      conicGradientFill.internalID = 7
      conicGradientFill.displayName = "Color Wheel"
      conicGradientFill.centerX = .with {
        $0.set(num: 1, den: 2)
      }
      conicGradientFill.centerY = .with {
        $0.set(num: 1, den: 2)
      }
      conicGradientFill.startAngleRadians = .with {
        $0.set(num: 0, den: 1)
      }
      conicGradientFill.startExtendedSrgbColor.red = 95.0 / 255.0
      conicGradientFill.startExtendedSrgbColor.green = 178.0 / 255.0
      conicGradientFill.startExtendedSrgbColor.blue = 203.0 / 255.0
      conicGradientFill.startExtendedSrgbColor.alpha = 1
      conicGradientFill.endExtendedSrgbColor.red = 1
      conicGradientFill.endExtendedSrgbColor.green = 1
      conicGradientFill.endExtendedSrgbColor.blue = 1
      conicGradientFill.endExtendedSrgbColor.alpha = 1
      var conicGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      conicGradientWrapper.conicGradientFill = conicGradientFill

      var clock = Ldtx_Workspace_V4_ClockComponent()
      clock.internalID = 8
      clock.displayName = "On Air Clock"
      clock.width = .with {
        $0.set(num: 1, den: 6)
      }
      clock.height = .with {
        $0.set(num: 2, den: 27)
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
      intervalTrigger.intervalSeconds = .with {
        $0.set(num: 5, den: 1)
      }
      var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
      triggerWrapper.intervalTrigger = intervalTrigger
      var ocrVision = Ldtx_Workspace_V4_OcrVision()
      ocrVision.internalID = 10
      ocrVision.displayName = "Program Text OCR"
      ocrVision.videoComponentInternalID = vfxSource.internalID
      ocrVision.triggers = [triggerWrapper]
      var ocrVisionWrapper = Ldtx_Workspace_V4_VisionWrapper()
      ocrVisionWrapper.ocrVision = ocrVision
      definition.visions = [ocrVisionWrapper]

      return definition
    }

  }
#endif
