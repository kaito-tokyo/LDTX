// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

enum WorkspaceResourceFactory {
  static func makeAudioInput(id: UInt64, name: String) -> Ldtx_Workspace_V4_AudioInputDevice {
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = id
    device.displayName = name
    return device
  }

  static func makeVFXSource(id: UInt64, name: String)
    -> Ldtx_Workspace_V4_VideoComponentWrapper
  {
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = id
    component.displayName = name
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.vfxSource = component
    return wrapper
  }

  static func makeSolidColor(id: UInt64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
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
    wrapper.solidColorFill = component
    return wrapper
  }

  static func makeClock(id: UInt64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    var component = Ldtx_Workspace_V4_ClockComponent()
    component.internalID = id
    component.displayName = name
    component.width = .with {
      $0.set(num: 1, den: 6)
    }
    component.height = .with {
      $0.set(num: 2, den: 27)
    }
    component.foregroundExtendedSrgbColor = opaqueWhite
    var background = Ldtx_Workspace_V4_Color()
    background.alpha = 0.65
    component.backgroundExtendedSrgbColor = background
    component.showsSeconds = true
    component.uses24HourTime = true
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.clock = component
    return wrapper
  }

  static func makeLinearGradient(id: UInt64, name: String)
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
    wrapper.linearGradientFill = component
    return wrapper
  }

  static func makeRadialGradient(id: UInt64, name: String)
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
    wrapper.radialGradientFill = component
    return wrapper
  }

  static func makeConicGradient(id: UInt64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper
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
    wrapper.conicGradientFill = component
    return wrapper
  }

  static func makeTestPattern(id: UInt64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    var component = Ldtx_Workspace_V4_TestPatternComponent()
    component.internalID = id
    component.displayName = name
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.testPattern = component
    return wrapper
  }

  static func makeOcrVision(id: UInt64, name: String, componentID: UInt64)
    -> Ldtx_Workspace_V4_VisionWrapper
  {
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = .with {
      $0.set(num: 5, den: 1)
    }
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.intervalTrigger = trigger
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = id
    vision.displayName = name
    vision.videoComponentInternalID = componentID
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
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

  static func nextInternalID() -> UInt64 {
    let milliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    return ((milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15)
      | UInt64.random(in: 0...0x7fff)
  }

}
