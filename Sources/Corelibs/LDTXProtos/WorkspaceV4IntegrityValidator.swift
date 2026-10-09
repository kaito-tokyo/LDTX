// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Validates the internal-ID references in one V4 Workspace definition.
public enum WorkspaceV4IntegrityValidator {
  public static let minimumVisionIntervalSeconds = 0.1

  public static func validate(_ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) throws {
    if let issue = validationIssues(in: definition).first { throw issue.error }
  }

  private static func validationIssues(
    in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [WorkspaceV4ValidationIssue] {
    var issues: [WorkspaceV4ValidationIssue] = []
    func check(_ context: String, _ body: () throws -> Void) {
      do { try body() } catch { issues.append(.init(context: context, error: error)) }
    }
    check("Canvas") { try validateCanvasConfiguration(definition.canvasConfiguration) }
    var componentIDs: [UInt64] = []
    for component in definition.videoComponents {
      check("Video Component") { componentIDs.append(try videoComponentID(component)) }
    }
    var visionIDs: [UInt64] = []
    for vision in definition.visions {
      check("Vision") { visionIDs.append(try visionID(vision)) }
    }
    let allIDs =
      definition.audioDevices.map(\.internalID) + componentIDs
      + definition.programs.map(\.internalID) + visionIDs
    if !allIDs.allSatisfy(isValidInternalID) {
      issues.append(.init(context: "Workspace", error: WorkspaceV4IntegrityError.invalidInternalID))
    }
    if Set(allIDs).count != allIDs.count {
      issues.append(
        .init(context: "Workspace", error: WorkspaceV4IntegrityError.duplicateInternalID))
    }
    let videoLayerIDs = Set(componentIDs)
    let vfxSourceIDs = Set(
      definition.videoComponents.compactMap { wrapper -> UInt64? in
        guard case .vfxSource(let source) = wrapper.videoComponent else { return nil }
        return source.internalID
      })
    if definition.canvasConfiguration.hasPtsMasterVfxSourceInternalID {
      let id = definition.canvasConfiguration.ptsMasterVfxSourceInternalID
      if !vfxSourceIDs.contains(id) {
        issues.append(
          .init(context: "Canvas", error: WorkspaceV4IntegrityError.missingVfxSource(id)))
      }
    }
    for component in definition.videoComponents {
      check(videoComponentName(component)) { try validateVideoComponent(component) }
    }
    for vision in definition.visions {
      check(visionName(vision)) { try validate(vision, componentIDs: videoLayerIDs) }
    }
    var names = Set<String>()
    let values =
      definition.audioDevices.map(\.displayName)
      + definition.videoComponents.map { videoComponentName($0) }
      + definition.visions.map { visionName($0) } + definition.programs.map(\.displayName)
    for name in values {
      if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(
          .init(context: "Workspace", error: WorkspaceV4IntegrityError.emptyDisplayName))
      } else if !names.insert(name).inserted {
        issues.append(
          .init(context: "Workspace", error: WorkspaceV4IntegrityError.duplicateDisplayName(name)))
      }
    }
    return issues
  }

  private static func validateVideoComponent(
    _ component: Ldtx_Workspace_V4_VideoComponentWrapper
  ) throws {
    switch component.videoComponent {
    case .vfxSource(let source):
      guard source.effects.allSatisfy({ $0.videoEffect != nil }) else {
        throw WorkspaceV4IntegrityError.missingConcreteDefinition
      }
    case .radialGradientFill(let fill):
      try validateRationals(
        ([
          fill.hasCenterX ? fill.centerX : nil,
          fill.hasCenterY ? fill.centerY : nil,
          fill.hasInnerRadius ? fill.innerRadius : nil,
          fill.hasOuterRadius ? fill.outerRadius : nil,
        ] as [(any Rational32Value)?]).compactMap { $0 })
      guard unitInterval(fill.centerX),
        unitInterval(fill.centerY),
        unitInterval(fill.innerRadius),
        unitInterval(fill.outerRadius),
        lessThan(fill.innerRadius, fill.outerRadius)
      else { throw WorkspaceV4IntegrityError.invalidRadialGradient }
      try validateColor(fill.innerExtendedSrgbColor)
      try validateColor(fill.outerExtendedSrgbColor)
    case .linearGradientFill(let fill):
      try validateRationals(
        ([
          fill.hasStartX ? fill.startX : nil,
          fill.hasStartY ? fill.startY : nil,
          fill.hasEndX ? fill.endX : nil,
          fill.hasEndY ? fill.endY : nil,
        ] as [(any Rational32Value)?]).compactMap { $0 })
      guard unitInterval(fill.startX),
        unitInterval(fill.startY),
        unitInterval(fill.endX),
        unitInterval(fill.endY),
        lessThan(fill.startX, fill.endX)
          || lessThan(fill.endX, fill.startX)
          || lessThan(fill.startY, fill.endY)
          || lessThan(fill.endY, fill.startY)
      else { throw WorkspaceV4IntegrityError.invalidLinearGradient }
      try validateColor(fill.startExtendedSrgbColor)
      try validateColor(fill.endExtendedSrgbColor)
    case .conicGradientFill(let fill):
      try validateRationals(
        ([
          fill.hasCenterX ? fill.centerX : nil,
          fill.hasCenterY ? fill.centerY : nil,
          fill.hasStartAngleRadians ? fill.startAngleRadians : nil,
        ] as [(any Rational32Value)?]).compactMap { $0 })
      guard unitInterval(fill.centerX),
        unitInterval(fill.centerY)
      else { throw WorkspaceV4IntegrityError.invalidConicGradient }
      try validateColor(fill.startExtendedSrgbColor)
      try validateColor(fill.endExtendedSrgbColor)
    case .solidColorFill(let fill):
      try validateColor(fill.extendedSrgbColor)
    case .clock(let clock):
      try validateRationals(
        ([
          clock.hasWidth ? clock.width : nil,
          clock.hasHeight ? clock.height : nil,
        ] as [(any Rational32Value)?]).compactMap { $0 })
      guard unitInterval(clock.width, positive: true),
        unitInterval(clock.height, positive: true),
        clock.outlines.count <= 2
      else { throw WorkspaceV4IntegrityError.invalidClockGeometry }
      for outline in clock.outlines {
        if outline.hasThickness { try validateRationals([outline.thickness]) }
        guard outline.thickness.numerator >= 0 else {
          throw WorkspaceV4IntegrityError.invalidClockGeometry
        }
      }
    default:
      break
    }
  }

  private static func unitInterval(_ value: some Rational32Value, positive: Bool = false)
    -> Bool
  {
    (positive ? value.numerator > 0 : value.numerator >= 0)
      && UInt32(value.numerator) <= max(value.denominator, 1)
  }

  private static func lessThan(
    _ lhs: Ldtx_Workspace_V4_Rational32,
    _ rhs: Ldtx_Workspace_V4_Rational32
  ) -> Bool {
    Int128(lhs.numerator) * Int128(max(rhs.denominator, 1))
      < Int128(rhs.numerator) * Int128(max(lhs.denominator, 1))
  }

  private static func fitsUnitInterval(
    _ start: Ldtx_Workspace_V4_Rational32,
    _ size: Ldtx_Workspace_V4_Rational32DefaultOne
  ) -> Bool {
    UInt128(start.numerator) * UInt128(size.denominator)
      <= UInt128(size.denominator - UInt32(size.numerator)) * UInt128(max(start.denominator, 1))
  }

  private static func validateRationals(_ values: [any Rational32Value]) throws {
    guard values.allSatisfy({ $0.denominator > 0 || $0.numerator == 0 }) else {
      throw WorkspaceV4IntegrityError.invalidRational
    }
  }

  private static func validateColor(_ color: Ldtx_Workspace_V4_Color) throws {
    guard color.red.isFinite, color.green.isFinite, color.blue.isFinite,
      color.alpha.isFinite,
      (0...1).contains(color.alpha)
    else { throw WorkspaceV4IntegrityError.invalidColor }
  }

  private static func videoComponentName(
    _ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper
  ) -> String {
    wrapper.displayName ?? ""
  }

  private static func visionName(_ wrapper: Ldtx_Workspace_V4_VisionWrapper) -> String {
    wrapper.displayName ?? ""
  }

  /// Validates both documents before they are persisted or used by a runtime.
  public static func validate(_ workspace: WorkspaceV4Bundle) throws {
    if let issue = validationIssues(in: workspace).first { throw issue.error }
  }

  public static func validationIssues(in workspace: WorkspaceV4Bundle)
    -> [WorkspaceV4ValidationIssue]
  {
    let definition = workspace.definition
    var issues = validationIssues(in: definition)
    let audioInputIDs = Set(definition.audioDevices.map(\.internalID))
    let videoComponentIDs = Set(definition.videoComponents.compactMap { try? videoComponentID($0) })
    for id in workspace.preferences.audioChannelGainsDecibels.keys.sorted()
    where !audioInputIDs.contains(id) {
      issues.append(
        .init(context: "Audio Mix", error: WorkspaceV4IntegrityError.missingAudioInputDevice(id)))
    }
    for (id, gain) in workspace.preferences.audioChannelGainsDecibels.sorted(by: { $0.key < $1.key }
    ) {
      do { try validateRationals([gain]) } catch {
        issues.append(.init(context: "Audio device \(id)", error: error))
      }
    }
    for (canvas, preferences) in [
      ("Landscape", workspace.preferences.landscapeProgramPreferences),
      ("Portrait", workspace.preferences.portraitProgramPreferences),
    ] {
      for programID in preferences.keys.sorted() {
        guard let program = definition.programs.first(where: { $0.internalID == programID }) else {
          issues.append(
            .init(context: canvas, error: WorkspaceV4IntegrityError.missingProgram(programID)))
          continue
        }
        let preference = preferences[programID]!
        let context = "\(program.displayName) / \(canvas)"
        let layers = preference.videoLayerInternalIds
        if Set(layers).count != layers.count {
          issues.append(
            .init(context: context, error: WorkspaceV4IntegrityError.duplicateVideoLayer(programID))
          )
        }
        for id in layers where !videoComponentIDs.contains(id) {
          issues.append(
            .init(context: context, error: WorkspaceV4IntegrityError.missingVideoLayer(id)))
        }
        if preference.hasAudioMasterVolumeDecibels {
          do { try validateRationals([preference.audioMasterVolumeDecibels]) } catch {
            issues.append(.init(context: context, error: error))
          }
        }
        for id in preference.audioChannelMuted.keys.sorted() where !audioInputIDs.contains(id) {
          issues.append(
            .init(context: context, error: WorkspaceV4IntegrityError.missingAudioInputDevice(id)))
        }
        let layerIDs = Set(preference.videoLayerTransforms.keys).union(
          preference.videoLayerHidden.keys)
        for id in layerIDs.sorted() {
          guard videoComponentIDs.contains(id) else {
            issues.append(
              .init(context: context, error: WorkspaceV4IntegrityError.missingVideoLayer(id)))
            continue
          }
          if let transform = preference.videoLayerTransforms[id] {
            do { try validateTransform(transform) } catch {
              issues.append(.init(context: "\(context) / Video Component \(id)", error: error))
            }
          }
        }
      }
    }
    return issues
  }

  public static func videoComponentID(_ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper) throws
    -> UInt64
  {
    guard wrapper.videoComponent != nil else {
      throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
    guard let id = wrapper.internalID else {
      throw WorkspaceV4IntegrityError.invalidInternalID
    }
    return id
  }

  public static func visionID(_ wrapper: Ldtx_Workspace_V4_VisionWrapper) throws -> UInt64 {
    guard wrapper.vision != nil else {
      throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
    guard let id = wrapper.internalID else {
      throw WorkspaceV4IntegrityError.invalidInternalID
    }
    return id
  }

  public static func validateRegionOfInterest(_ region: Ldtx_Workspace_V4_VisionRegionOfInterest)
    throws
  {
    try validateRationals(
      ([
        region.hasX ? region.x : nil,
        region.hasY ? region.y : nil,
        region.hasWidth ? region.width : nil,
        region.hasHeight ? region.height : nil,
      ] as [(any Rational32Value)?]).compactMap { $0 })
    guard unitInterval(region.x),
      unitInterval(region.y),
      unitInterval(region.width, positive: true),
      unitInterval(region.height, positive: true),
      fitsUnitInterval(region.x, region.width),
      fitsUnitInterval(region.y, region.height)
    else { throw WorkspaceV4IntegrityError.invalidVisionRegionOfInterest }
  }

  private static func isValidInternalID(_ value: UInt64) -> Bool {
    value != 0 && value & (UInt64(1) << 63) == 0
  }

  private static func validate(
    _ wrapper: Ldtx_Workspace_V4_VisionWrapper,
    componentIDs: Set<UInt64>
  ) throws {
    let inputID: UInt64
    let triggers: [Ldtx_Workspace_V4_VisionTriggerWrapper]
    let region: Ldtx_Workspace_V4_VisionRegionOfInterest?
    let minimumTextHeight: Ldtx_Workspace_V4_Rational32?
    switch wrapper.vision {
    case .ocrVision(let vision):
      guard vision.hasVideoComponentInternalID else {
        throw WorkspaceV4IntegrityError.missingVisionVideoComponent
      }
      inputID = vision.videoComponentInternalID
      triggers = vision.triggers
      region = vision.hasRegionOfInterest ? vision.regionOfInterest : nil
      minimumTextHeight = vision.hasMinimumTextHeight ? vision.minimumTextHeight : nil
    case .createMlImageClassificationVision(let vision):
      guard vision.hasVideoComponentInternalID else {
        throw WorkspaceV4IntegrityError.missingVisionVideoComponent
      }
      inputID = vision.videoComponentInternalID
      triggers = vision.triggers
      region = vision.hasRegionOfInterest ? vision.regionOfInterest : nil
      minimumTextHeight = nil
    case nil:
      throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
    guard componentIDs.contains(inputID) else {
      throw WorkspaceV4IntegrityError.missingVideoComponent(inputID)
    }
    if let minimumTextHeight {
      try validateRationals([minimumTextHeight])
    }
    for trigger in triggers {
      guard case .intervalTrigger(let interval)? = trigger.trigger else {
        throw WorkspaceV4IntegrityError.missingConcreteDefinition
      }
      try validateRationals(
        ([interval.hasIntervalSeconds ? interval.intervalSeconds : nil] as [(any Rational32Value)?])
          .compactMap {
            $0
          })
      guard
        !lessThan(
          interval.intervalSeconds,
          .with {
            $0.set(num: 1, den: 10)
          })
      else {
        throw WorkspaceV4IntegrityError.invalidVisionInterval
      }
    }
    if let region {
      try validateRegionOfInterest(region)
    }
    if let minimumTextHeight {
      guard unitInterval(minimumTextHeight)
      else {
        throw WorkspaceV4IntegrityError.invalidMinimumTextHeight
      }
    }
  }

  private static func validateCanvasConfiguration(
    _ canvas: Ldtx_Workspace_V4_CanvasConfiguration
  ) throws {
    guard canvas.frameRate == 0 || (1...240).contains(canvas.frameRate) else {
      throw WorkspaceV4IntegrityError.unsupportedFrameRate(canvas.frameRate)
    }
    if !canvas.landscapeProfileID.isEmpty,
      canvas.landscapeProfileID != "sdr-landscape-1080p60"
    {
      throw WorkspaceV4IntegrityError.unsupportedOutputProfile(canvas.landscapeProfileID)
    }
    if !canvas.portraitProfileID.isEmpty,
      canvas.portraitProfileID != "sdr-portrait-1080p60"
    {
      throw WorkspaceV4IntegrityError.unsupportedOutputProfile(canvas.portraitProfileID)
    }
  }

  public static func validateTransform(_ transform: Ldtx_Workspace_V4_BasicTransform) throws {
    try validateRationals(
      ([
        (transform.hasTranslationX ? transform.translationX : nil),
        (transform.hasTranslationY ? transform.translationY : nil),
        (transform.hasScaleX ? transform.scaleX : nil),
        (transform.hasScaleY ? transform.scaleY : nil),
        (transform.hasTopInset ? transform.topInset : nil),
        (transform.hasRightInset ? transform.rightInset : nil),
        (transform.hasBottomInset ? transform.bottomInset : nil),
        (transform.hasLeftInset ? transform.leftInset : nil),
      ] as [(any Rational32Value)?]).compactMap { $0 })
    guard
      [
        (transform.hasTranslationX ? transform.translationX : nil),
        (transform.hasTranslationY ? transform.translationY : nil),
        (transform.hasTopInset ? transform.topInset : nil),
        (transform.hasRightInset ? transform.rightInset : nil),
        (transform.hasBottomInset ? transform.bottomInset : nil),
        (transform.hasLeftInset ? transform.leftInset : nil),
      ].compactMap({ $0 }).allSatisfy({ unitInterval($0) })
    else { throw WorkspaceV4IntegrityError.invalidBasicTransform }
  }

}

public enum WorkspaceV4IntegrityError: Error, Equatable, Sendable {
  case missingConcreteDefinition
  case invalidInternalID
  case duplicateInternalID
  case duplicateDisplayName(String)
  case emptyDisplayName
  case duplicateVideoLayer(UInt64)
  case missingVideoLayer(UInt64)
  case missingProgram(UInt64)
  case missingVideoComponent(UInt64)
  case missingVfxSource(UInt64)
  case missingAudioInputDevice(UInt64)
  case missingVisionVideoComponent
  case invalidVisionInterval
  case invalidVisionRegionOfInterest
  case invalidMinimumTextHeight
  case unsupportedOutputProfile(String)
  case unsupportedFrameRate(UInt32)
  case invalidRadialGradient
  case invalidBasicTransform
  case invalidLinearGradient
  case invalidConicGradient
  case invalidClockGeometry
  case invalidColor
  case invalidRational
}

public struct WorkspaceV4ValidationIssue: Sendable {
  public let context: String
  public let error: any Error
}

extension WorkspaceV4IntegrityError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingConcreteDefinition: "A resource has no concrete definition."
    case .invalidInternalID: "Resource IDs must be nonzero and must not have the sign bit set."
    case .duplicateInternalID: "Resource IDs must be unique across the Workspace."
    case .duplicateDisplayName(let name): "The name ‘\(name)’ is used by more than one resource."
    case .emptyDisplayName: "Resource names must not be empty."
    case .duplicateVideoLayer(let id): "Program \(id) contains duplicate video layers."
    case .missingVideoLayer(let id):
      "Video Component \(id) referenced by a layer or its preferences is missing."
    case .missingProgram(let id): "Program \(id) referenced by preferences is missing."
    case .missingVideoComponent(let id): "Video Component \(id) referenced by OCR is missing."
    case .missingVfxSource(let id): "VFX Source \(id) referenced by the PTS master is missing."
    case .missingAudioInputDevice(let id):
      "Audio device \(id) referenced by preferences is missing."
    case .missingVisionVideoComponent: "Vision must reference a Video Component."
    case .invalidVisionInterval: "OCR intervals must be finite and at least 0.1 seconds."
    case .invalidVisionRegionOfInterest:
      "The Vision region must have positive dimensions and fit within the image."
    case .invalidMinimumTextHeight: "Minimum text height must be between 0 and 1."
    case .unsupportedOutputProfile(let profile): "The output profile ‘\(profile)’ is unsupported."
    case .unsupportedFrameRate(let rate): "The frame rate \(rate) is unsupported."
    case .invalidRadialGradient:
      "Radial gradient coordinates and radii must be valid normalized values."
    case .invalidBasicTransform:
      "Transform positions and crop insets must be between 0 and 1. All values must be finite."
    case .invalidLinearGradient: "Linear gradient endpoints must be distinct and between 0 and 1."
    case .invalidConicGradient:
      "Conic gradient coordinates must be between 0 and 1 and its angle must be finite."
    case .invalidClockGeometry:
      "Clock dimensions must be greater than 0 and at most 1, with at most two outlines."
    case .invalidRational: "Rational values must have a denominator greater than zero."
    case .invalidColor: "Color components must be finite; alpha must be between 0 and 1."
    }
  }
}
