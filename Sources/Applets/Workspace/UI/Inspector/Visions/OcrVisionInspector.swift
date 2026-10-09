// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import SwiftUI

struct OcrVisionInspector: View {
  @Bindable var storeService: WorkspaceStoreService
  @Binding var vision: Ldtx_Workspace_V4_OcrVision

  @State var languages: String
  @State var customWords: String
  @State var minimumTextHeight: String
  @State var x: String
  @State var xDenominator: String
  @State var y: String
  @State var yDenominator: String
  @State var width: String
  @State var widthDenominator: String
  @State var height: String
  @State var heightDenominator: String
  @State var validatorID = UUID()
  @State var submittedInputs: [String] = []

  init(storeService: WorkspaceStoreService, vision: Binding<Ldtx_Workspace_V4_OcrVision>) {
    self.storeService = storeService
    self._vision = vision
    let value = vision.wrappedValue
    self._languages = State(initialValue: value.recognitionLanguages.joined(separator: ", "))
    self._customWords = State(initialValue: value.customWords.joined(separator: ", "))
    self._minimumTextHeight = State(
      initialValue: RationalFormatStyle().format(value.minimumTextHeight))
    let profile = WorkspaceCanvasTarget.landscape.defaultProfile
    let xFields = RationalFractionInput.fields(
      for: value.regionOfInterest.x, defaultDenominator: UInt32(profile.width))
    self._x = State(initialValue: xFields.numerator)
    self._xDenominator = State(initialValue: xFields.denominator)
    let yFields = RationalFractionInput.fields(
      for: value.regionOfInterest.y, defaultDenominator: UInt32(profile.height))
    self._y = State(initialValue: yFields.numerator)
    self._yDenominator = State(initialValue: yFields.denominator)
    let widthFields = RationalFractionInput.fields(
      for: value.regionOfInterest.width, defaultDenominator: UInt32(profile.width))
    self._width = State(initialValue: widthFields.numerator)
    self._widthDenominator = State(initialValue: widthFields.denominator)
    let heightFields = RationalFractionInput.fields(
      for: value.regionOfInterest.height, defaultDenominator: UInt32(profile.height))
    self._height = State(initialValue: heightFields.numerator)
    self._heightDenominator = State(initialValue: heightFields.denominator)
  }

  var body: some View {
    Form {
      Section("OCR Vision") {
        TextField("Name", text: $vision.displayName)
        Picker("Video Component", selection: $vision.videoComponentInternalIDIfPresent) {
          Text("Unassigned").tag(UInt64?.none)
          ForEach(storeService.videoComponentOptions) { option in
            Text(option.name).tag(Optional(option.id))
          }
          if let selected = vision.videoComponentInternalIDIfPresent,
            !storeService.videoComponentOptions.contains(where: { $0.id == selected })
          {
            Text("Unavailable").tag(Optional(selected))
          }
        }
        .pickerStyle(.menu)
        Picker("Update Interval", selection: $vision.triggers) {
          Text("Manual").tag([Ldtx_Workspace_V4_VisionTriggerWrapper]())
          Text("Every 1 Second").tag([intervalTrigger(seconds: 1)])
          Text("Every 5 Seconds").tag([intervalTrigger(seconds: 5)])
          Text("Every 10 Seconds").tag([intervalTrigger(seconds: 10)])
          Text("Every 30 Seconds").tag([intervalTrigger(seconds: 30)])
        }
      }
      .disabled(storeService.isOutputActive)
      Section("Text Recognition") {
        LabeledContent("Recognition", value: "Accurate")
        Toggle(
          "Language Correction",
          isOn: $vision.usesLanguageCorrection
        )
        TextField("Languages (comma separated)", text: $languages)
        TextField("Custom Words (comma separated)", text: $customWords)
        LabeledContent("Minimum Text Height") {
          TextField(
            "Fraction", text: $minimumTextHeight
          )
          .multilineTextAlignment(.trailing)
          .frame(width: 90)
        }
      }
      .disabled(storeService.isOutputActive)
      Section("Region of Interest") {
        LabeledContent("X") {
          Rational32TextField(
            numerator: $x, denominator: $xDenominator,
            accessibilityLabel: "X", onSubmit: submitEdits)
        }
        LabeledContent("Y") {
          Rational32TextField(
            numerator: $y, denominator: $yDenominator,
            accessibilityLabel: "Y", onSubmit: submitEdits)
        }
        LabeledContent("Width") {
          Rational32TextField(
            numerator: $width, denominator: $widthDenominator,
            accessibilityLabel: "Width", onSubmit: submitEdits)
        }
        LabeledContent("Height") {
          Rational32TextField(
            numerator: $height, denominator: $heightDenominator,
            accessibilityLabel: "Height", onSubmit: submitEdits)
        }
      }
      .disabled(storeService.isOutputActive)
      Section("Recognition Result") {
        if let failure = storeService.visionFailureMessages[vision.internalID] {
          Text(failure).foregroundStyle(.red)
        } else if let result = storeService.visionResults[vision.internalID] {
          Text(result.isEmpty ? "No text recognized." : result).textSelection(.enabled)
        } else {
          Text("Waiting for recognition.").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onSubmit { submitEdits() }
    .onAppear {
      if submittedInputs.isEmpty { submittedInputs = inputs }
      storeService.registerInspectorEditValidator(
        id: validatorID, hasChanges: { inputs != submittedInputs },
        submit: { try commitEdits() }
      ) {
        _ = try Self.validatedRegion(
          x: x, y: y, width: width, height: height, xDenominator: xDenominator,
          yDenominator: yDenominator,
          widthDenominator: widthDenominator, heightDenominator: heightDenominator)
        _ = try validatedMinimumTextHeight()
      }
    }
    .onChange(of: inputs) { storeService.refreshUnconfirmedChanges() }
    .onDisappear { storeService.removeInspectorEditValidator(id: validatorID) }
  }

  func intervalTrigger(seconds: Int32) -> Ldtx_Workspace_V4_VisionTriggerWrapper {
    var trigger = Ldtx_Workspace_V4_VisionTriggerWrapper()
    trigger.intervalTrigger.intervalSeconds.set(num: seconds, den: 1)
    return trigger
  }

  var inputs: [String] {
    [
      languages, customWords, minimumTextHeight, x, xDenominator, y, yDenominator, width,
      widthDenominator, height, heightDenominator,
    ]
  }

  func submitEdits() {
    guard !storeService.isOutputActive else { return }
    do { try commitEdits() } catch { storeService.reportInputValidationError(error) }
  }

  func commitEdits() throws {
    let region = try Self.validatedRegion(
      x: x, y: y, width: width, height: height, xDenominator: xDenominator,
      yDenominator: yDenominator,
      widthDenominator: widthDenominator, heightDenominator: heightDenominator)
    let minimumHeight = try validatedMinimumTextHeight()
    var updated = vision
    updated.recognitionLanguages = Self.commaSeparatedValues(languages)
    updated.customWords = Self.commaSeparatedValues(customWords)
    updated.minimumTextHeight = minimumHeight
    updated.regionOfInterest = region
    vision = updated
    submittedInputs = inputs
    storeService.refreshUnconfirmedChanges()
  }

  static func validatedRegion(
    x: String, y: String, width: String, height: String,
    xDenominator: String = "1", yDenominator: String = "1",
    widthDenominator: String = "1", heightDenominator: String = "1"
  ) throws
    -> Ldtx_Workspace_V4_VisionRegionOfInterest
  {
    do {
      var region = Ldtx_Workspace_V4_VisionRegionOfInterest()
      region.x = try RationalFractionInput.parse(
        numerator: x, denominator: xDenominator, as: Ldtx_Workspace_V4_Rational32.self)
      region.y = try RationalFractionInput.parse(
        numerator: y, denominator: yDenominator, as: Ldtx_Workspace_V4_Rational32.self)
      region.width = try RationalFractionInput.parse(
        numerator: width, denominator: widthDenominator,
        as: Ldtx_Workspace_V4_Rational32DefaultOne.self)
      region.height = try RationalFractionInput.parse(
        numerator: height, denominator: heightDenominator,
        as: Ldtx_Workspace_V4_Rational32DefaultOne.self)
      try WorkspaceV4IntegrityValidator.validateRegionOfInterest(region)
      return region
    } catch {
      throw WorkspaceSelectionError(
        message: "Correct the OCR ROI before leaving this Inspector. " + error.localizedDescription)
    }
  }

  func validatedMinimumTextHeight() throws -> Ldtx_Workspace_V4_Rational32 {
    let value = try RationalParseStrategy().parse(minimumTextHeight)
    guard value.double.isFinite, (0...1).contains(value.double) else {
      throw WorkspaceSelectionError(message: "Minimum Text Height must be between 0 and 1.")
    }
    return value
  }

  static func commaSeparatedValues(_ text: String) -> [String] {
    text.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
  }

}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .ocrVision, internalID: 10))
    @Bindable var boundStore = storeService
    if let vision = $boundStore.ocrVision(internalID: 10) {
      OcrVisionInspector(storeService: storeService, vision: vision)
        .frame(width: 480, height: 800, alignment: .topLeading)
    }
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .ocrVision, internalID: 10),
      isOutputActive: true)
    @Bindable var boundStore = storeService
    if let vision = $boundStore.ocrVision(internalID: 10) {
      OcrVisionInspector(storeService: storeService, vision: vision)
        .frame(width: 480, height: 800, alignment: .topLeading)
    }
  }

#endif
