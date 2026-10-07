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
        guard case .vfxSource(let source) = wrapper.definition else { return nil }
        return source.internalID
      })
    if definition.canvasConfiguration.hasPtsMasterVfxSourceInternalID {
      let id = definition.canvasConfiguration.ptsMasterVfxSourceInternalID
      if !vfxSourceIDs.contains(id) {
        issues.append(
          .init(context: "Canvas", error: WorkspaceV4IntegrityError.missingVfxSource(id)))
      }
    }
    for program in definition.programs {
      let landscape = program.landscapeVideoLayerInternalIds
      let portrait = program.portraitVideoLayerInternalIds
      if Set(landscape).count != landscape.count || Set(portrait).count != portrait.count {
        issues.append(
          .init(
            context: program.displayName,
            error: WorkspaceV4IntegrityError.duplicateVideoLayer(program.internalID)))
      }
      for id in landscape + portrait where !videoLayerIDs.contains(id) {
        issues.append(
          .init(
            context: program.displayName,
            error: WorkspaceV4IntegrityError.missingVideoLayer(id)))
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
    switch component.definition {
    case .vfxSource(let source):
      guard source.effects.allSatisfy({ $0.definition != nil }) else {
        throw WorkspaceV4IntegrityError.missingConcreteDefinition
      }
    case .radialGradientFill(let fill):
      try validateRationals(
        [
          fill.hasCenterXRational ? fill.centerXRational : nil,
          fill.hasCenterYRational ? fill.centerYRational : nil,
          fill.hasInnerRadiusRational ? fill.innerRadiusRational : nil,
          fill.hasOuterRadiusRational ? fill.outerRadiusRational : nil,
        ].compactMap { $0 })
      guard unitInterval(fill.centerXRational),
        unitInterval(fill.centerYRational),
        unitInterval(fill.innerRadiusRational),
        unitInterval(fill.outerRadiusRational),
        lessThan(fill.innerRadiusRational, fill.outerRadiusRational)
      else { throw WorkspaceV4IntegrityError.invalidRadialGradient }
      try validateColor(fill.innerColor)
      try validateColor(fill.outerColor)
    case .linearGradientFill(let fill):
      try validateRationals(
        [
          fill.hasStartXRational ? fill.startXRational : nil,
          fill.hasStartYRational ? fill.startYRational : nil,
          fill.hasEndXRational ? fill.endXRational : nil,
          fill.hasEndYRational ? fill.endYRational : nil,
        ].compactMap { $0 })
      guard unitInterval(fill.startXRational),
        unitInterval(fill.startYRational),
        unitInterval(fill.endXRational),
        unitInterval(fill.endYRational),
        lessThan(fill.startXRational, fill.endXRational)
          || lessThan(fill.endXRational, fill.startXRational)
          || lessThan(fill.startYRational, fill.endYRational)
          || lessThan(fill.endYRational, fill.startYRational)
      else { throw WorkspaceV4IntegrityError.invalidLinearGradient }
      try validateColor(fill.startColor)
      try validateColor(fill.endColor)
    case .conicGradientFill(let fill):
      try validateRationals(
        [
          fill.hasCenterXRational ? fill.centerXRational : nil,
          fill.hasCenterYRational ? fill.centerYRational : nil,
          fill.hasStartAngleRadiansRational ? fill.startAngleRadiansRational : nil,
        ].compactMap { $0 })
      guard unitInterval(fill.centerXRational),
        unitInterval(fill.centerYRational)
      else { throw WorkspaceV4IntegrityError.invalidConicGradient }
      try validateColor(fill.startColor)
      try validateColor(fill.endColor)
    case .solidColorFill(let fill):
      let color = fill.color
      guard color.red.isFinite, color.green.isFinite, color.blue.isFinite,
        color.alpha.isFinite,
        (0...1).contains(color.red), (0...1).contains(color.green),
        (0...1).contains(color.blue), (0...1).contains(color.alpha)
      else { throw WorkspaceV4IntegrityError.invalidColor }
    case .clock(let clock):
      try validateRationals(
        [
          clock.hasWidthRational ? clock.widthRational : nil,
          clock.hasHeightRational ? clock.heightRational : nil,
        ].compactMap { $0 })
      guard unitInterval(clock.widthRational, positive: true),
        unitInterval(clock.heightRational, positive: true),
        clock.outlines.count <= 2
      else { throw WorkspaceV4IntegrityError.invalidClockGeometry }
      for outline in clock.outlines {
        if outline.hasThicknessRational { try validateRationals([outline.thicknessRational]) }
        guard outline.thicknessRational.numerator >= 0 else {
          throw WorkspaceV4IntegrityError.invalidClockGeometry
        }
      }
    default:
      break
    }
  }

  private static func unitInterval(_ value: Ldtx_Workspace_V4_Rational32, positive: Bool = false)
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
    _ size: Ldtx_Workspace_V4_Rational32
  ) -> Bool {
    UInt128(start.numerator) * UInt128(size.denominator)
      <= UInt128(size.denominator - UInt32(size.numerator)) * UInt128(max(start.denominator, 1))
  }

  private static func validateRationals(_ values: [Ldtx_Workspace_V4_Rational32]) throws {
    guard values.allSatisfy({ $0.denominator > 0 || $0.numerator == 0 }) else {
      throw WorkspaceV4IntegrityError.invalidRational
    }
  }

  private static func validateColor(_ color: Ldtx_Workspace_V4_ExtendedSrgbColor) throws {
    guard color.red.isFinite, color.green.isFinite, color.blue.isFinite,
      color.alpha.isFinite,
      (0...1).contains(color.red), (0...1).contains(color.green),
      (0...1).contains(color.blue), (0...1).contains(color.alpha)
    else { throw WorkspaceV4IntegrityError.invalidColor }
  }

  private static func videoComponentName(
    _ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper
  ) -> String {
    switch wrapper.definition {
    case .solidColorFill(let component): component.displayName
    case .linearGradientFill(let component): component.displayName
    case .radialGradientFill(let component): component.displayName
    case .conicGradientFill(let component): component.displayName
    case .vfxSource(let component): component.displayName
    case .clock(let component): component.displayName
    case .testPattern(let component): component.displayName
    case nil: ""
    }
  }

  private static func visionName(_ wrapper: Ldtx_Workspace_V4_VisionWrapper) -> String {
    switch wrapper.definition {
    case .ocrVision(let vision): vision.displayName
    case nil: ""
    }
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
    switch wrapper.definition {
    case .solidColorFill(let component): component.internalID
    case .linearGradientFill(let component): component.internalID
    case .radialGradientFill(let component): component.internalID
    case .conicGradientFill(let component): component.internalID
    case .vfxSource(let component): component.internalID
    case .clock(let component): component.internalID
    case .testPattern(let component): component.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  public static func visionID(_ wrapper: Ldtx_Workspace_V4_VisionWrapper) throws -> UInt64 {
    switch wrapper.definition {
    case .ocrVision(let vision): vision.internalID
    case nil: throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
  }

  public static func validateRegionOfInterest(_ region: Ldtx_Workspace_V4_VisionRegionOfInterest)
    throws
  {
    try validateRationals(
      [
        region.hasXRational ? region.xRational : nil,
        region.hasYRational ? region.yRational : nil,
        region.hasWidthRational ? region.widthRational : nil,
        region.hasHeightRational ? region.heightRational : nil,
      ].compactMap { $0 })
    guard unitInterval(region.xRational),
      unitInterval(region.yRational),
      unitInterval(region.widthRational, positive: true),
      unitInterval(region.heightRational, positive: true),
      fitsUnitInterval(region.xRational, region.widthRational),
      fitsUnitInterval(region.yRational, region.heightRational)
    else { throw WorkspaceV4IntegrityError.invalidVisionRegionOfInterest }
  }

  private static func isValidInternalID(_ value: UInt64) -> Bool {
    value != 0 && value & (UInt64(1) << 63) == 0
  }

  private static func validate(
    _ wrapper: Ldtx_Workspace_V4_VisionWrapper,
    componentIDs: Set<UInt64>
  ) throws {
    guard case .ocrVision(let vision)? = wrapper.definition else {
      throw WorkspaceV4IntegrityError.missingConcreteDefinition
    }
    guard case .videoComponentInternalID(let inputID)? = vision.source else {
      throw WorkspaceV4IntegrityError.missingVisionVideoComponent
    }
    guard componentIDs.contains(inputID) else {
      throw WorkspaceV4IntegrityError.missingVideoComponent(inputID)
    }
    if vision.hasMinimumTextHeightRational {
      try validateRationals([vision.minimumTextHeightRational])
    }
    for trigger in vision.triggers {
      guard case .intervalTrigger(let interval)? = trigger.definition else {
        throw WorkspaceV4IntegrityError.missingConcreteDefinition
      }
      try validateRationals(
        [interval.hasIntervalSecondsRational ? interval.intervalSecondsRational : nil].compactMap {
          $0
        })
      guard
        !lessThan(
          interval.intervalSecondsRational,
          .with {
            $0.set(num: 1, den: 10)
          })
      else {
        throw WorkspaceV4IntegrityError.invalidVisionInterval
      }
    }
    if vision.hasRegionOfInterest {
      try validateRegionOfInterest(vision.regionOfInterest)
    }
    if vision.hasMinimumTextHeightRational {
      guard unitInterval(vision.minimumTextHeightRational)
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
      [
        transform.translationX,
        transform.translationY,
        transform.scaleX,
        transform.scaleY,
        transform.topInset,
        transform.rightInset,
        transform.bottomInset,
        transform.leftInset,
      ].compactMap { $0 })
    guard
      [
        transform.translationXRational, transform.translationYRational,
        transform.topInsetRational, transform.rightInsetRational,
        transform.bottomInsetRational, transform.leftInsetRational,
      ].allSatisfy({
        unitInterval($0)
      }),
      !transform.hasScaleXRational || transform.scaleXRational.numerator >= 0,
      !transform.hasScaleYRational || transform.scaleYRational.numerator >= 0
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
    case .missingVisionVideoComponent: "OCR must reference a Video Component."
    case .invalidVisionInterval: "OCR intervals must be finite and at least 0.1 seconds."
    case .invalidVisionRegionOfInterest:
      "The OCR region must have positive dimensions and fit within the image."
    case .invalidMinimumTextHeight: "Minimum text height must be between 0 and 1."
    case .unsupportedOutputProfile(let profile): "The output profile ‘\(profile)’ is unsupported."
    case .unsupportedFrameRate(let rate): "The frame rate \(rate) is unsupported."
    case .invalidRadialGradient:
      "Radial gradient coordinates and radii must be valid normalized values."
    case .invalidBasicTransform:
      "Transform positions and crop insets must be between 0 and 1; scales must be nonnegative. All values must be finite."
    case .invalidLinearGradient: "Linear gradient endpoints must be distinct and between 0 and 1."
    case .invalidConicGradient:
      "Conic gradient coordinates must be between 0 and 1 and its angle must be finite."
    case .invalidClockGeometry:
      "Clock dimensions must be greater than 0 and at most 1, with at most two outlines."
    case .invalidRational: "Rational values must have a denominator greater than zero."
    case .invalidColor: "Color components must be finite and between 0 and 1."
    }
  }
}
