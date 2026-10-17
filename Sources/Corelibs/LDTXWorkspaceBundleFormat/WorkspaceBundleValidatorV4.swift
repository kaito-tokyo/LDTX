// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXVariableStore

/// Validates V4 bundle metadata and content at the Read/Write boundary.
public struct WorkspaceBundleValidatorV4 {
  public let bundleURL: URL

  public init(at bundleURL: URL) {
    self.bundleURL = bundleURL
  }

  var infoURL: URL {
    bundleURL.appending(path: "Info.plist", directoryHint: .notDirectory)
  }

  public func validate() throws -> String {
    let infoData = try Data(contentsOf: infoURL)
    guard
      let info = try? WorkspaceBundleInfoV4(data: infoData),
      info.packageType == "BNDL",
      info.workspaceVersion == 4
    else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: infoURL])
    }

    return info.workspaceBundleVersion
  }
}

/// The persistence gate for V4 content. Validation never modifies the supplied values.
extension WorkspaceBundleValidatorV4 {
  public static let minimumVisionIntervalSeconds = 0.1

  public static func validationIssues(in workspace: WorkspaceV4Bundle)
    -> [WorkspaceV4ValidationIssue]
  {
    var collector = Collector()
    collector.definition(workspace.definition)
    collector.preferences(workspace.preferences, definition: workspace.definition)
    for (path, value) in [
      ("definitionExternalID", workspace.definitionExternalID),
      ("preferencesExternalID", workspace.preferencesExternalID),
      ("outputSettingsExternalID", workspace.outputSettingsExternalID),
    ] {
      guard let value else { continue }
      guard let uuid = UUID(uuidString: value), uuid.uuid.6 >> 4 == 7,
        uuid.uuid.8 & 0xc0 == 0x80
      else {
        collector.add(path, .invalidEnvelopeID)
        continue
      }
    }
    for (id, url) in workspace.visionModels.sorted(by: { $0.key < $1.key }) {
      let path = "visionModels[\(id)]"
      if id <= 0 { collector.add(path, .invalidModelID(id), id: id) }
      do { try WorkspaceModelFiles.validateModel(at: url) } catch {
        collector.add(path, .invalidModelResource(error.localizedDescription), id: id)
      }
    }
    for (index, wrapper) in workspace.definition.visions.enumerated() {
      guard case .ldtxSceneDetectorVision(let vision) = wrapper.vision else { continue }
      let path = "definition.visions[\(index)].ldtx_scene_detector_vision.model_internal_id"
      if vision.modelInternalID < 0 {
        collector.add(path, .invalidModelID(vision.modelInternalID), id: vision.internalID)
      } else if vision.modelInternalID > 0, workspace.visionModels[vision.modelInternalID] == nil {
        collector.add(path, .missingVisionModel(vision.modelInternalID), id: vision.internalID)
      }
    }
    return collector.issues
  }

  public static func validationIssues(
    in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  ) -> [WorkspaceV4ValidationIssue] {
    var collector = Collector()
    collector.definition(definition)
    collector.preferences(preferences, definition: definition)
    return collector.issues
  }

  public static func validate(_ workspace: WorkspaceV4Bundle) throws {
    try requireNoIssues(validationIssues(in: workspace))
  }

  public static func validate(_ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) throws {
    var collector = Collector()
    collector.definition(definition)
    try requireNoIssues(collector.issues)
  }

  public static func validateRegionOfInterest(
    _ region: Ldtx_Workspace_V4_VisionRegionOfInterest,
    inputSize: (width: UInt32, height: UInt32) = (1, 1)
  )
    throws
  {
    var collector = Collector()
    collector.region(region, path: "region_of_interest", id: nil, inputSize: inputSize)
    try requireNoIssues(collector.issues)
  }

  public static func validateTransform(_ transform: Ldtx_Workspace_V4_BasicTransform) throws {
    var collector = Collector()
    collector.transform(transform, path: "transform", id: nil)
    try requireNoIssues(collector.issues)
  }

  private static func requireNoIssues(_ issues: [WorkspaceV4ValidationIssue]) throws {
    if !issues.isEmpty { throw WorkspaceV4ValidationError(diagnostics: issues) }
  }

  private struct Collector {
    var issues: [WorkspaceV4ValidationIssue] = []

    mutating func add(_ path: String, _ error: WorkspaceV4IntegrityError, id: Int64? = nil) {
      issues.append(.init(path: path, entityID: id, error: error))
    }

    // A failed denominator check stops only computations dependent on this value.
    mutating func rational(_ value: any Rational32Value, path: String, id: Int64?) -> Bool {
      guard value.den > 0 else {
        add(path + ".den", .invalidRational, id: id)
        return false
      }
      return true
    }

    mutating func unit(
      _ value: any Rational32Value, path: String, id: Int64?,
      positive: Bool = false, error: WorkspaceV4IntegrityError
    ) -> Bool {
      guard rational(value, path: path, id: id) else { return false }
      guard positive ? value.num > 0 : value.num >= 0, Int64(value.num) <= Int64(value.den) else {
        add(path, error, id: id)
        return false
      }
      return true
    }

    func less(_ lhs: any Rational32Value, _ rhs: any Rational32Value) -> Bool {
      Int128(lhs.num) * Int128(rhs.den) < Int128(rhs.num) * Int128(lhs.den)
    }

    func componentPath(_ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper, _ path: String) -> String
    {
      switch wrapper.videoComponent {
      case .solidColorFill: path + ".solid_color_fill"
      case .linearGradientFill: path + ".linear_gradient_fill"
      case .radialGradientFill: path + ".radial_gradient_fill"
      case .conicGradientFill: path + ".conic_gradient_fill"
      case .vfxSource: path + ".vfx_source"
      case .clock: path + ".clock"
      case .dynamicText: path + ".dynamic_text"
      case .testPattern: path + ".test_pattern"
      case nil: path
      }
    }

    func visionPath(_ wrapper: Ldtx_Workspace_V4_VisionWrapper, _ path: String) -> String {
      switch wrapper.vision {
      case .ocrVision: path + ".ocr_vision"
      case .ldtxSceneDetectorVision: path + ".ldtx_scene_detector_vision"
      case nil: path
      }
    }

    mutating func region(
      _ region: Ldtx_Workspace_V4_VisionRegionOfInterest, path: String, id: Int64?,
      inputSize: (width: UInt32, height: UInt32) = (1, 1)
    ) {
      guard let region = try? region.resolved(inputSize: inputSize) else {
        add(path, .invalidVisionRegionOfInterest, id: id)
        return
      }
      let x = unit(region.x, path: path + ".x", id: id, error: .invalidVisionRegionOfInterest)
      let y = unit(region.y, path: path + ".y", id: id, error: .invalidVisionRegionOfInterest)
      let w = unit(
        region.width, path: path + ".width", id: id, positive: true,
        error: .invalidVisionRegionOfInterest)
      let h = unit(
        region.height, path: path + ".height", id: id, positive: true,
        error: .invalidVisionRegionOfInterest)
      if x && w, !fits(region.x, region.width) {
        add(path + ".x+width", .invalidVisionRegionOfInterest, id: id)
      }
      if y && h, !fits(region.y, region.height) {
        add(path + ".y+height", .invalidVisionRegionOfInterest, id: id)
      }
    }

    func fits(_ start: any Rational32Value, _ size: any Rational32Value) -> Bool {
      Int128(start.num) * Int128(size.den) + Int128(size.num) * Int128(start.den)
        <= Int128(start.den) * Int128(size.den)
    }

    mutating func color(_ value: Ldtx_Workspace_V4_Color, path: String, id: Int64?) {
      for (field, component) in [
        ("red", value.red), ("green", value.green), ("blue", value.blue), ("alpha", value.alpha),
      ] {
        if !component.isFinite || (field == "alpha" && !(0...1).contains(component)) {
          add(path + "." + field, .invalidColor, id: id)
        }
      }
    }

    mutating func transform(_ value: Ldtx_Workspace_V4_BasicTransform, path: String, id: Int64?) {
      for (field, rationalValue) in [
        ("translation_x", value.hasTranslationX ? value.translationX : nil),
        ("translation_y", value.hasTranslationY ? value.translationY : nil),
        ("top_inset", value.hasTopInset ? value.topInset : nil),
        ("right_inset", value.hasRightInset ? value.rightInset : nil),
        ("bottom_inset", value.hasBottomInset ? value.bottomInset : nil),
        ("left_inset", value.hasLeftInset ? value.leftInset : nil),
      ] {
        if let rationalValue {
          _ = unit(rationalValue, path: path + "." + field, id: id, error: .invalidBasicTransform)
        }
      }
      if value.hasScaleX { _ = rational(value.scaleX, path: path + ".scale_x", id: id) }
      if value.hasScaleY { _ = rational(value.scaleY, path: path + ".scale_y", id: id) }
    }

    mutating func definition(_ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) {
      func entities() -> [(String, Int64?, String?, Bool)] {
        definition.audioDevices.enumerated().map {
          (
            "definition.audio_devices[\($0.offset)]", $0.element.internalID, $0.element.displayName,
            true
          )
        }
          + definition.videoComponents.enumerated().map {
            (
              componentPath($0.element, "definition.video_components[\($0.offset)]"),
              $0.element.internalID, $0.element.displayName, $0.element.videoComponent != nil
            )
          }
          + definition.programs.enumerated().map {
            (
              "definition.programs[\($0.offset)]", $0.element.internalID, $0.element.displayName,
              true
            )
          }
          + definition.visions.enumerated().map {
            (
              visionPath($0.element, "definition.visions[\($0.offset)]"), $0.element.internalID,
              $0.element.displayName, $0.element.vision != nil
            )
          }
      }
      let resources = entities()
      let idCounts = Dictionary(grouping: resources.compactMap { $0.1 }, by: { $0 }).mapValues(
        \.count)
      let nameCounts = Dictionary(grouping: resources.compactMap { $0.2 }, by: { $0 }).mapValues(
        \.count)
      for (path, id, name, concrete) in resources {
        if !concrete {
          add(path, .missingConcreteDefinition, id: id)
          continue
        }
        if let id, id > 0 {
          if idCounts[id, default: 0] > 1 {
            add(path + ".internal_id", .duplicateInternalID, id: id)
          }
        } else {
          add(path + ".internal_id", .invalidInternalID, id: id)
        }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          if nameCounts[name, default: 0] > 1 {
            add(path + ".display_name", .duplicateDisplayName(name), id: id)
          }
        } else {
          add(path + ".display_name", .emptyDisplayName, id: id)
        }
      }
      let canvas = definition.canvasConfiguration
      if canvas.frameRate != 0 && !(1...240).contains(canvas.frameRate) {
        add("definition.canvas_configuration.frame_rate", .unsupportedFrameRate(canvas.frameRate))
      }
      for (field, profile) in [
        ("landscape_profile_id", canvas.landscapeProfileID),
        ("portrait_profile_id", canvas.portraitProfileID),
      ] {
        let expected =
          field == "landscape_profile_id" ? "sdr-landscape-1080p60" : "sdr-portrait-1080p60"
        if !profile.isEmpty && profile != expected {
          add("definition.canvas_configuration." + field, .unsupportedOutputProfile(profile))
        }
      }
      let components = definition.videoComponents
      let sources = Set(
        definition.videoComponents.compactMap { wrapper -> Int64? in
          if case .vfxSource(let source) = wrapper.videoComponent { return source.internalID }
          return nil
        })
      if canvas.hasPtsMasterVfxSourceInternalID,
        !sources.contains(canvas.ptsMasterVfxSourceInternalID)
      {
        add(
          "definition.canvas_configuration.pts_master_vfx_source_internal_id",
          .missingVfxSource(canvas.ptsMasterVfxSourceInternalID))
      }
      for (index, component) in definition.videoComponents.enumerated() {
        videoComponent(
          component, path: "definition.video_components[\(index)]", id: component.internalID)
      }
      for (index, wrapper) in definition.visions.enumerated() {
        vision(wrapper, path: "definition.visions[\(index)]", components: components)
      }
    }

    mutating func videoComponent(
      _ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper, path: String, id: Int64?
    ) {
      let path = componentPath(wrapper, path)
      switch wrapper.videoComponent {
      case .vfxSource(let source):
        for (i, effect) in source.effects.enumerated() where effect.videoEffect == nil {
          add(path + ".effects[\(i)]", .missingConcreteDefinition, id: id)
        }
      case .solidColorFill(let fill):
        color(fill.extendedSrgbColor, path: path + ".extended_srgb_color", id: id)
      case .linearGradientFill(let fill):
        let a = unit(fill.startX, path: path + ".start_x", id: id, error: .invalidLinearGradient)
        let b = unit(fill.startY, path: path + ".start_y", id: id, error: .invalidLinearGradient)
        let c = unit(fill.endX, path: path + ".end_x", id: id, error: .invalidLinearGradient)
        let d = unit(fill.endY, path: path + ".end_y", id: id, error: .invalidLinearGradient)
        if a && b && c && d,
          !less(fill.startX, fill.endX) && !less(fill.endX, fill.startX)
            && !less(fill.startY, fill.endY) && !less(fill.endY, fill.startY)
        {
          add(path, .invalidLinearGradient, id: id)
        }
        color(fill.startExtendedSrgbColor, path: path + ".start_extended_srgb_color", id: id)
        color(fill.endExtendedSrgbColor, path: path + ".end_extended_srgb_color", id: id)
      case .radialGradientFill(let fill):
        _ = unit(fill.centerX, path: path + ".center_x", id: id, error: .invalidRadialGradient)
        _ = unit(fill.centerY, path: path + ".center_y", id: id, error: .invalidRadialGradient)
        let a = unit(
          fill.innerRadius, path: path + ".inner_radius", id: id, error: .invalidRadialGradient)
        let b = unit(
          fill.outerRadius, path: path + ".outer_radius", id: id, error: .invalidRadialGradient)
        if a && b, !less(fill.innerRadius, fill.outerRadius) {
          add(path + ".inner_radius<outer_radius", .invalidRadialGradient, id: id)
        }
        color(fill.innerExtendedSrgbColor, path: path + ".inner_extended_srgb_color", id: id)
        color(fill.outerExtendedSrgbColor, path: path + ".outer_extended_srgb_color", id: id)
      case .conicGradientFill(let fill):
        _ = unit(fill.centerX, path: path + ".center_x", id: id, error: .invalidConicGradient)
        _ = unit(fill.centerY, path: path + ".center_y", id: id, error: .invalidConicGradient)
        _ = rational(fill.startAngleRadians, path: path + ".start_angle_radians", id: id)
        color(fill.startExtendedSrgbColor, path: path + ".start_extended_srgb_color", id: id)
        color(fill.endExtendedSrgbColor, path: path + ".end_extended_srgb_color", id: id)
      case .dynamicText(let text):
        if text.hasMacroDocument {
          if (try? VariableMacroDocument(xml: text.macroDocument)) == nil {
            add(path + ".macro_document", .invalidVariableMacro, id: id)
          }
        }
        _ = unit(
          text.width, path: path + ".width", id: id, positive: true,
          error: .invalidDynamicTextGeometry)
        _ = unit(
          text.height, path: path + ".height", id: id, positive: true,
          error: .invalidDynamicTextGeometry)
        color(
          text.foregroundExtendedSrgbColor, path: path + ".foreground_extended_srgb_color", id: id)
      case .clock(let clock):
        _ = unit(
          clock.width, path: path + ".width", id: id, positive: true, error: .invalidClockGeometry)
        _ = unit(
          clock.height, path: path + ".height", id: id, positive: true, error: .invalidClockGeometry
        )
        if clock.outlines.count > 2 { add(path + ".outlines", .invalidClockGeometry, id: id) }
        for (i, outline) in clock.outlines.enumerated() {
          let p = path + ".outlines[\(i)].thickness"
          if rational(outline.thickness, path: p, id: id), outline.thickness.num < 0 {
            add(p, .invalidClockGeometry, id: id)
          }
        }
      default: break
      }
    }

    mutating func vision(
      _ wrapper: Ldtx_Workspace_V4_VisionWrapper, path: String,
      components: [Ldtx_Workspace_V4_VideoComponentWrapper]
    ) {
      let path = visionPath(wrapper, path)
      let input: Int64
      let present: Bool
      let triggers: [Ldtx_Workspace_V4_VisionTriggerWrapper]
      let roi: Ldtx_Workspace_V4_VisionRegionOfInterest?
      let id = wrapper.internalID
      switch wrapper.vision {
      case .ocrVision(let vision):
        input = vision.videoComponentInternalID
        present = vision.hasVideoComponentInternalID
        triggers = vision.triggers
        roi = vision.hasRegionOfInterest ? vision.regionOfInterest : nil
        if vision.hasMinimumTextHeight {
          _ = unit(
            vision.minimumTextHeight, path: path + ".minimum_text_height", id: id,
            error: .invalidMinimumTextHeight)
        }
      case .ldtxSceneDetectorVision(let vision):
        input = vision.videoComponentInternalID
        present = vision.hasVideoComponentInternalID
        triggers = vision.triggers
        roi = vision.hasRegionOfInterest ? vision.regionOfInterest : nil
      case nil: return
      }
      if !present {
        add(path + ".video_component_internal_id", .missingVisionVideoComponent, id: id)
      } else if let component = components.first(where: { $0.internalID == input }) {
        if case .ldtxSceneDetectorVision = wrapper.vision {
          if !component.canBeVisionInput {
            add(path + ".video_component_internal_id", .unsupportedVisionInput, id: id)
          } else if component.renderingSize.map({ $0.width > 0 && $0.height > 0 }) != true {
            add(path + ".video_component_internal_id", .invalidVisionInputSize, id: id)
          }
        }
      } else {
        add(path + ".video_component_internal_id", .missingVideoComponent(input), id: id)
      }
      for (i, trigger) in triggers.enumerated() {
        let p = path + ".triggers[\(i)]"
        guard case .intervalTrigger(let interval) = trigger.trigger else {
          add(p, .missingConcreteDefinition, id: id)
          continue
        }
        if rational(interval.intervalSeconds, path: p + ".interval_seconds", id: id),
          Int128(interval.intervalSeconds.num) * 10 < Int128(interval.intervalSeconds.den)
        {
          add(p + ".interval_seconds", .invalidVisionInterval, id: id)
        }
      }
      if let roi {
        let size = components.first(where: { $0.internalID == input })?.renderingSize
        region(roi, path: path + ".region_of_interest", id: id, inputSize: size ?? (1, 1))
      }
    }

    mutating func preferences(
      _ preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
      definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
    ) {
      let audio = Set(definition.audioDevices.map(\.internalID))
      let components = Set(definition.videoComponents.compactMap(\.internalID))
      for (id, gain) in preferences.audioChannelGainsDecibels.sorted(by: { $0.key < $1.key }) {
        let p = "preferences.audio_channel_gains_decibels[\(id)]"
        if !audio.contains(id) { add(p, .missingAudioInputDevice(id), id: id) }
        if rational(gain, path: p, id: id), !(-80...20).contains(gain.double) {
          add(p, .invalidAudioChannelGain, id: id)
        }
      }
      for (canvas, values) in [
        ("Landscape", preferences.landscapeProgramPreferences),
        ("Portrait", preferences.portraitProgramPreferences),
      ] {
        for (id, preference) in values.sorted(by: { $0.key < $1.key }) {
          let p = "preferences.\(canvas)[\(id)]"
          if !definition.programs.contains(where: { $0.internalID == id }) {
            add(p, .missingProgram(id), id: id)
          }
          if Set(preference.videoLayerInternalIds).count != preference.videoLayerInternalIds.count {
            add(p + ".video_layer_internal_ids", .duplicateVideoLayer(id), id: id)
          }
          for (index, component) in preference.videoLayerInternalIds.enumerated()
          where !components.contains(component) {
            add(p + ".video_layer_internal_ids[\(index)]", .missingVideoLayer(component), id: id)
          }
          if preference.hasAudioMasterVolumeDecibels {
            let valid = rational(
              preference.audioMasterVolumeDecibels, path: p + ".audio_master_volume_decibels",
              id: id)
            if valid, !(-80...20).contains(preference.audioMasterVolumeDecibels.double) {
              add(p + ".audio_master_volume_decibels", .invalidMasterVolume, id: id)
            }
          }
          for audioID in preference.audioChannelMuted.keys.sorted() where !audio.contains(audioID) {
            add(p + ".audio_channel_muted[\(audioID)]", .missingAudioInputDevice(audioID), id: id)
          }
          for component in preference.videoLayerHidden.keys.sorted()
          where !components.contains(component) {
            add(p + ".video_layer_hidden[\(component)]", .missingVideoLayer(component), id: id)
          }
          for component in preference.videoLayerTransforms.keys.sorted() {
            let layer = p + ".video_layer_transforms[\(component)]"
            if !components.contains(component) { add(layer, .missingVideoLayer(component), id: id) }
            if let value = preference.videoLayerTransforms[component] {
              transform(value, path: layer, id: component)
            }
          }
        }
      }
    }
  }
}

/// A structured diagnostic with a stable field path and machine-readable violation.
public struct WorkspaceV4ValidationIssue: Equatable, Sendable {
  public let path: String
  public let entityID: Int64?
  public let error: WorkspaceV4IntegrityError
  public init(path: String, entityID: Int64? = nil, error: WorkspaceV4IntegrityError) {
    self.path = path
    self.entityID = entityID
    self.error = error
  }
}

/// Read/Write reject the entire bundle while retaining every diagnostic for presentation.
public struct WorkspaceV4ValidationError: LocalizedError, Sendable {
  public let diagnostics: [WorkspaceV4ValidationIssue]
  public init(diagnostics: [WorkspaceV4ValidationIssue]) { self.diagnostics = diagnostics }
  public var errorDescription: String? {
    "The Workspace contains invalid content.\n\n"
      + diagnostics.map { "\($0.path): \($0.error.localizedDescription)" }.joined(separator: "\n\n")
  }
  public var recoverySuggestion: String? { "Correct the listed settings and try again." }
}

public enum WorkspaceV4IntegrityError: Error, Equatable, Sendable {
  case missingConcreteDefinition
  case invalidInternalID
  case duplicateInternalID
  case duplicateDisplayName(String)
  case emptyDisplayName
  case duplicateVideoLayer(Int64)
  case missingVideoLayer(Int64)
  case missingProgram(Int64)
  case missingVideoComponent(Int64)
  case missingVfxSource(Int64)
  case missingAudioInputDevice(Int64)
  case missingVisionVideoComponent
  case invalidVisionInterval
  case invalidVisionRegionOfInterest
  case unsupportedVisionInput
  case invalidVisionInputSize
  case invalidMasterVolume
  case invalidAudioChannelGain
  case invalidMinimumTextHeight
  case unsupportedOutputProfile(String)
  case unsupportedFrameRate(UInt32)
  case invalidRadialGradient
  case invalidBasicTransform
  case invalidLinearGradient
  case invalidConicGradient
  case invalidClockGeometry
  case invalidDynamicTextGeometry
  case invalidVariableMacro
  case invalidColor
  case invalidRational
  case invalidEnvelopeID
  case invalidModelID(Int64)
  case missingVisionModel(Int64)
  case invalidModelResource(String)
}

extension WorkspaceV4IntegrityError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingConcreteDefinition: "A resource has no concrete definition."
    case .invalidInternalID: "Resource IDs must be positive."
    case .duplicateInternalID: "Resource IDs must be unique across the Workspace."
    case .duplicateDisplayName(let name): "The name ‘\(name)’ is used by more than one resource."
    case .emptyDisplayName: "Resource names must not be empty."
    case .duplicateVideoLayer(let id): "Program \(id) contains duplicate video layers."
    case .missingVideoLayer(let id):
      "Video Component \(id) referenced by a layer or its preferences is missing."
    case .missingProgram(let id): "Program \(id) referenced by preferences is missing."
    case .missingVideoComponent(let id): "Video Component \(id) referenced by Vision is missing."
    case .missingVfxSource(let id): "VFX Source \(id) referenced by the PTS master is missing."
    case .missingAudioInputDevice(let id):
      "Audio device \(id) referenced by preferences is missing."
    case .missingVisionVideoComponent: "Vision must reference a Video Component."
    case .unsupportedVisionInput: "The Video Component cannot be used as a Vision input."
    case .invalidMasterVolume: "Master volume must be between -80 and 20 dB."
    case .invalidAudioChannelGain: "Audio channel gain must be between -80 and 20 dB."
    case .invalidVisionInputSize: "The Vision input must define a positive image width and height."
    case .invalidVisionInterval: "Vision intervals must be finite and at least 0.1 seconds."
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
    case .invalidDynamicTextGeometry:
      "Dynamic Text width and height must be greater than zero and at most one."
    case .invalidVariableMacro:
      "Variable Macro segments must contain text or a valid structured variable reference."
    case .invalidClockGeometry:
      "Clock dimensions must be greater than 0 and at most 1, with at most two outlines."
    case .invalidModelID(let id):
      "Model ID \(id) must be positive, or zero for an unassigned Vision."
    case .missingVisionModel(let id): "Model \(id) referenced by Vision is missing."
    case .invalidModelResource(let reason): "The model resource is invalid: \(reason)"
    case .invalidRational: "Rational values must have a denominator greater than zero."
    case .invalidEnvelopeID: "Document envelope IDs must be valid UUIDv7 identifiers."
    case .invalidColor: "Color components must be finite; alpha must be between 0 and 1."
    }
  }
}
