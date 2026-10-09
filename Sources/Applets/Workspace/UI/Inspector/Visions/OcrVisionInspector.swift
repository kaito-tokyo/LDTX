// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct OcrVisionInspector: View {
  @Bindable var storeService: WorkspaceStoreService
  @Binding var vision: Ldtx_Workspace_V4_OcrVision

  @State private var languages: String
  @State private var customWords: String
  @State private var minimumTextHeight: String
  @State private var x: String
  @State private var y: String
  @State private var width: String
  @State private var height: String
  @State private var validatorID = UUID()

  init(storeService: WorkspaceStoreService, vision: Binding<Ldtx_Workspace_V4_OcrVision>) {
    self.storeService = storeService
    self._vision = vision
    let value = vision.wrappedValue
    self._languages = State(initialValue: value.recognitionLanguages.joined(separator: ", "))
    self._customWords = State(initialValue: value.customWords.joined(separator: ", "))
    self._minimumTextHeight = State(
      initialValue: RationalFormatStyle().format(value.minimumTextHeight))
    self._x = State(initialValue: RationalFormatStyle().format(value.regionOfInterest.x))
    self._y = State(initialValue: RationalFormatStyle().format(value.regionOfInterest.y))
    self._width = State(
      initialValue: RationalValueFormatStyle<Ldtx_Workspace_V4_Rational32DefaultOne>().format(
        value.regionOfInterest.width))
    self._height = State(
      initialValue: RationalValueFormatStyle<Ldtx_Workspace_V4_Rational32DefaultOne>().format(
        value.regionOfInterest.height))
  }

  var body: some View {
    Form {
      Section("OCR Vision") {
        TextField("Name", text: $vision.displayName)
        WorkspaceSelectionField(
          title: "Video Component", current: vision.videoComponentInternalIDIfPresent,
          options: storeService.videoComponentOptions,
          clearTitle: "Remove Assignment", isEditable: !storeService.isOutputActive,
          reportError: { storeService.reportError($0) },
          commit: { selected in
            guard !storeService.isOutputActive,
              selected == nil
                || storeService.videoComponentOptions.contains(where: { $0.id == selected })
            else {
              throw WorkspaceSelectionError(
                message: "The input or Vision is no longer available for editing.")
            }
            vision.videoComponentInternalIDIfPresent = selected
            storeService.synchronizeVision()
          })
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
        regionField("X", text: $x)
        regionField("Y", text: $y)
        regionField(
          "Width", text: $width)
        regionField(
          "Height", text: $height)
        Text("Coordinates are normalized from 0 to 1.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .disabled(storeService.isOutputActive)
      Section {
        Button("Apply") { submitEdits() }
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
      storeService.registerInspectorEditValidator(id: validatorID) {
        _ = try Self.validatedRegion(x: x, y: y, width: width, height: height)
        _ = try validatedMinimumTextHeight()
      }
    }
    .onDisappear { storeService.removeInspectorEditValidator(id: validatorID) }
  }

  private func intervalTrigger(seconds: Int32) -> Ldtx_Workspace_V4_VisionTriggerWrapper {
    var trigger = Ldtx_Workspace_V4_VisionTriggerWrapper()
    trigger.intervalTrigger.intervalSeconds.set(num: seconds, den: 1)
    return trigger
  }

  private func regionField(
    _ title: String, text: Binding<String>
  ) -> some View {
    LabeledContent(title) {
      TextField(title, text: text)
        .multilineTextAlignment(.trailing)
        .frame(width: 90)
    }
  }

  private func submitEdits() {
    guard !storeService.isOutputActive else { return }
    do {
      let region = try Self.validatedRegion(x: x, y: y, width: width, height: height)
      let minimumHeight = try validatedMinimumTextHeight()
      var updated = vision
      updated.recognitionLanguages = Self.commaSeparatedValues(languages)
      updated.customWords = Self.commaSeparatedValues(customWords)
      updated.minimumTextHeight = minimumHeight
      updated.regionOfInterest = region
      vision = updated
    } catch {
      storeService.reportError(error)
    }
  }

  static func validatedRegion(x: String, y: String, width: String, height: String) throws
    -> Ldtx_Workspace_V4_VisionRegionOfInterest
  {
    do {
      var region = Ldtx_Workspace_V4_VisionRegionOfInterest()
      region.x = try RationalParseStrategy().parse(x)
      region.y = try RationalParseStrategy().parse(y)
      region.width = try RationalValueParseStrategy<Ldtx_Workspace_V4_Rational32DefaultOne>()
        .parse(width)
      region.height = try RationalValueParseStrategy<Ldtx_Workspace_V4_Rational32DefaultOne>()
        .parse(height)
      try WorkspaceV4IntegrityValidator.validateRegionOfInterest(region)
      return region
    } catch {
      throw WorkspaceSelectionError(
        message: "Correct the OCR ROI before leaving this Inspector. " + error.localizedDescription)
    }
  }

  private func validatedMinimumTextHeight() throws -> Ldtx_Workspace_V4_Rational32 {
    let value = try RationalParseStrategy().parse(minimumTextHeight)
    guard value.double.isFinite, (0...1).contains(value.double) else {
      throw WorkspaceSelectionError(message: "Minimum Text Height must be between 0 and 1.")
    }
    return value
  }

  private static func commaSeparatedValues(_ text: String) -> [String] {
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
