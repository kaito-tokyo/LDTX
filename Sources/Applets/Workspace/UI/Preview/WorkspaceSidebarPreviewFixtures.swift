// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
  import LDTXCorelibs

  @MainActor
  public enum WorkspaceSidebarPreviewFixtures {
    public static func makeUIState(
      inspectorSelector: WorkspaceInspectorSelector? = nil,
      isOutputActive: Bool = false
    ) -> WorkspaceDocument {
      WorkspaceDocument(
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
      vfxSourceWrapper.videoComponent = .vfxSource(vfxSource)

      var solidColorFill = Ldtx_Workspace_V4_FillSolidColorComponent()
      solidColorFill.internalID = 4
      solidColorFill.displayName = "Background"
      solidColorFill.extendedSrgbColor = .with {
        $0.red = 95.0 / 255.0
        $0.green = 178.0 / 255.0
        $0.blue = 203.0 / 255.0
        $0.alpha = 1
      }
      var solidColorWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      solidColorWrapper.videoComponent = .solidColorFill(solidColorFill)

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
      linearGradientFill.startExtendedSrgbColor = .with {
        $0.red = 95.0 / 255.0
        $0.green = 178.0 / 255.0
        $0.blue = 203.0 / 255.0
        $0.alpha = 1
      }
      linearGradientFill.endExtendedSrgbColor = .with {
        $0.red = 1
        $0.green = 1
        $0.blue = 1
        $0.alpha = 1
      }
      var linearGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      linearGradientWrapper.videoComponent = .linearGradientFill(linearGradientFill)

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
      radialGradientFill.innerExtendedSrgbColor = .with {
        $0.red = 95.0 / 255.0
        $0.green = 178.0 / 255.0
        $0.blue = 203.0 / 255.0
        $0.alpha = 1
      }
      radialGradientFill.outerExtendedSrgbColor = .with {
        $0.red = 1
        $0.green = 1
        $0.blue = 1
        $0.alpha = 1
      }
      var radialGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      radialGradientWrapper.videoComponent = .radialGradientFill(radialGradientFill)

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
      conicGradientFill.startExtendedSrgbColor = .with {
        $0.red = 95.0 / 255.0
        $0.green = 178.0 / 255.0
        $0.blue = 203.0 / 255.0
        $0.alpha = 1
      }
      conicGradientFill.endExtendedSrgbColor = .with {
        $0.red = 1
        $0.green = 1
        $0.blue = 1
        $0.alpha = 1
      }
      var conicGradientWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      conicGradientWrapper.videoComponent = .conicGradientFill(conicGradientFill)

      var clock = Ldtx_Workspace_V4_ClockComponent()
      clock.internalID = 8
      clock.displayName = "On Air Clock"
      clock.fontSize = .with { $0.set(num: 48, den: 1) }
      var clockWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      clockWrapper.videoComponent = .clock(clock)

      var testPattern = Ldtx_Workspace_V4_TestPatternComponent()
      testPattern.internalID = 9
      testPattern.displayName = "Color Bars"
      var testPatternWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      testPatternWrapper.videoComponent = .testPattern(testPattern)
      definition.videoComponents = [
        vfxSourceWrapper, solidColorWrapper, linearGradientWrapper, radialGradientWrapper,
        conicGradientWrapper, clockWrapper, testPatternWrapper,
      ]

      var intervalTrigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
      intervalTrigger.intervalSeconds = .with {
        $0.set(num: 5, den: 1)
      }
      var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
      triggerWrapper.trigger = .intervalTrigger(intervalTrigger)
      var ocrVision = Ldtx_Workspace_V4_OcrVision()
      ocrVision.internalID = 10
      ocrVision.displayName = "Program Text OCR"
      ocrVision.videoComponentInternalID = vfxSource.internalID
      ocrVision.triggers = [triggerWrapper]
      var ocrVisionWrapper = Ldtx_Workspace_V4_VisionWrapper()
      ocrVisionWrapper.vision = .ocrVision(ocrVision)
      definition.visions = [
        ocrVisionWrapper,
        WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
          id: 11, name: "Scene Classifier", componentID: 3),
      ]

      return definition
    }

  }
#endif
