// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
import LDTXRichText
import LDTXWorkspaceAppletModel

enum WorkspaceResourceFactory {
  static func makeDynamicText(id: Int64, name: String) throws
    -> Ldtx_Workspace_V4_VideoComponentWrapper
  {
    var text = Ldtx_Workspace_V4_DynamicTextComponent()
    text.internalID = id
    text.displayName = name
    text.rtfdDocument = try LDTXRichTextDocument(
      NSAttributedString(
        string: "Dynamic Text",
        attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.white])
    ).rtfd
    text.width = .with { $0.set(num: 1, den: 2) }
    text.height = .with { $0.set(num: 1, den: 10) }
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .dynamicText(text)
    return wrapper
  }

  static func makeAudioInput(id: Int64, name: String) -> Ldtx_Workspace_V4_AudioInputDevice {
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = id
    device.displayName = name
    return device
  }

  static func makeVFXSource(id: Int64, name: String)
    -> Ldtx_Workspace_V4_VideoComponentWrapper
  {
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = id
    component.displayName = name
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .vfxSource(component)
    return wrapper
  }

  static func makeSolidColor(id: Int64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    var color = Ldtx_Workspace_V4_Color()
    color.red = 0.2
    color.green = 0.2
    color.blue = 0.2
    color.alpha = 1
    var component = Ldtx_Workspace_V4_FillSolidColorComponent()
    component.internalID = id
    component.displayName = name
    component.extendedSrgbColor = color
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .solidColorFill(component)
    return wrapper
  }

  static func makeClock(id: Int64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    var component = Ldtx_Workspace_V4_ClockComponent()
    component.internalID = id
    component.displayName = name
    component.fontSize = .with { $0.set(num: 48, den: 1) }
    component.foregroundExtendedSrgbColor = opaqueWhite
    component.showsSeconds = true
    component.uses24HourTime = true
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .clock(component)
    return wrapper
  }

  static func makeLinearGradient(id: Int64, name: String)
    -> Ldtx_Workspace_V4_VideoComponentWrapper
  {
    var component = Ldtx_Workspace_V4_FillLinearGradientComponent()
    component.internalID = id
    component.displayName = name
    component.startExtendedSrgbColor = gradientStartColor
    component.endX = .with {
      $0.set(num: 1, den: 1)
    }
    component.endY = .with {
      $0.set(num: 1, den: 1)
    }
    component.endExtendedSrgbColor = gradientEndColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .linearGradientFill(component)
    return wrapper
  }

  static func makeRadialGradient(id: Int64, name: String)
    -> Ldtx_Workspace_V4_VideoComponentWrapper
  {
    var component = Ldtx_Workspace_V4_FillRadialGradientComponent()
    component.internalID = id
    component.displayName = name
    component.centerX = .with {
      $0.set(num: 1, den: 2)
    }
    component.centerY = .with {
      $0.set(num: 1, den: 2)
    }
    component.outerRadius = .with {
      $0.set(num: 1, den: 2)
    }
    component.innerExtendedSrgbColor = gradientStartColor
    component.outerExtendedSrgbColor = gradientEndColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .radialGradientFill(component)
    return wrapper
  }

  static func makeConicGradient(id: Int64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper
  {
    var component = Ldtx_Workspace_V4_FillConicGradientComponent()
    component.internalID = id
    component.displayName = name
    component.centerX = .with {
      $0.set(num: 1, den: 2)
    }
    component.centerY = .with {
      $0.set(num: 1, den: 2)
    }
    component.startExtendedSrgbColor = gradientStartColor
    component.endExtendedSrgbColor = gradientEndColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .conicGradientFill(component)
    return wrapper
  }

  static func makeTestPattern(id: Int64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    var component = Ldtx_Workspace_V4_TestPatternComponent()
    component.internalID = id
    component.displayName = name
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .testPattern(component)
    return wrapper
  }

  static func makeOcrVision(id: Int64, name: String, componentID: Int64)
    -> Ldtx_Workspace_V4_VisionWrapper
  {
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = .with {
      $0.set(num: 5, den: 1)
    }
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.trigger = .intervalTrigger(trigger)
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = id
    vision.displayName = name
    vision.videoComponentInternalID = componentID
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.vision = .ocrVision(vision)
    return wrapper
  }

  static func makeLdtxSceneDetectorVision(id: Int64, name: String, componentID: Int64)
    -> Ldtx_Workspace_V4_VisionWrapper
  {
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = .with {
      $0.set(num: 5, den: 1)
    }
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.trigger = .intervalTrigger(trigger)
    var vision = Ldtx_Workspace_V4_LdtxSceneDetectorVision()
    vision.internalID = id
    vision.displayName = name
    vision.videoComponentInternalID = componentID
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.vision = .ldtxSceneDetectorVision(vision)
    return wrapper
  }

  private static var gradientStartColor: Ldtx_Workspace_V4_Color {
    var color = Ldtx_Workspace_V4_Color()
    color.red = 1
    color.green = 1
    color.blue = 1
    color.alpha = 1
    return color
  }

  private static var gradientEndColor: Ldtx_Workspace_V4_Color {
    var color = Ldtx_Workspace_V4_Color()
    color.red = 0.15
    color.green = 0.35
    color.blue = 0.85
    color.alpha = 1
    return color
  }

  private static var opaqueWhite: Ldtx_Workspace_V4_Color { gradientStartColor }

  @MainActor private static let internalIDGenerator = WorkspaceInternalIDGenerator()

  @MainActor
  static func nextInternalID(
    in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4, additionalIDs: Set<Int64> = []
  ) -> Int64 {
    internalIDGenerator.next(in: definition, additionalIDs: additionalIDs)
  }

}
