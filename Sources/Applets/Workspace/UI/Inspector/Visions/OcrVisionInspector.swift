// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletModel
import SwiftUI

struct OcrVisionInspector: View {
  @Bindable var stateService: WorkspaceDocument
  @Binding var vision: Ldtx_Workspace_V4_OcrVision

  var canRun: () -> Bool = { false }
  var run: () -> Void = {}

  var body: some View {
    Form {
      Section("Recognition Result") {
        Button("Run", systemImage: "text.viewfinder", action: run)
          .disabled(stateService.isClosed || !canRun())
          .accessibilityIdentifier("workspace.runOCR")
        if let id = vision.internalID, let failure = stateService.visionFailureMessages[id] {
          Text(failure).foregroundStyle(.red)
        } else if let id = vision.internalID, let result = stateService.visionResults[id] {
          Text(result.isEmpty ? "No text recognized." : result).textSelection(.enabled)
        } else {
          Text("Waiting for recognition.").foregroundStyle(.secondary)
        }
      }
      Section("OCR Vision") {
        TextField("Name", text: $vision.displayName.defaulting(to: ""))
        VisionInputVideoComponentDropdown(
          videoComponents: stateService.workspaceDefinition.videoComponents,
          selection: $vision.videoComponentInternalIDIfPresent)
        TriggerEditor(triggers: $vision.triggers)
      }
      .disabled(stateService.isOutputActive)
      Section("Text Recognition") {
        LabeledContent("Recognition", value: "Accurate")
        Toggle(
          "Language Correction",
          isOn: $vision.usesLanguageCorrection.defaulting(to: false)
        )
        TextField(
          "Languages (comma separated)",
          text: Binding(
            get: { vision.recognitionLanguages.joined(separator: ", ") },
            set: { vision.recognitionLanguages = Self.commaSeparatedValues($0) }))
        TextField(
          "Custom Words (comma separated)",
          text: Binding(
            get: { vision.customWords.joined(separator: ", ") },
            set: { vision.customWords = Self.commaSeparatedValues($0) }))
        LabeledContent("Minimum Text Height") {
          TextField(
            "Fraction", value: $vision.minimumTextHeight.defaulting(to: .init()),
            format: RationalFormatStyle()
          )
          .multilineTextAlignment(.trailing)
          .frame(width: 90)
        }
      }
      .disabled(stateService.isOutputActive)
      Section("Region of Interest") {
        RegionOfInterestEditor(
          inputSize: stateService.workspaceDefinition.videoComponents.first {
            $0.internalID == vision.videoComponentInternalID
          }?.renderingSize ?? (1920, 1080), roi: $vision.regionOfInterest.defaulting(to: .init()))
      }
      .disabled(stateService.isOutputActive)
    }
    .formStyle(.grouped)
  }

  static func commaSeparatedValues(_ text: String) -> [String] {
    text.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
  }

}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .ocrVision, internalID: 10))
    @Bindable var boundStore = stateService
    if let vision = $boundStore.ocrVision(internalID: 10) {
      OcrVisionInspector(
        stateService: stateService, vision: vision
      )
      .frame(width: 480, height: 800, alignment: .topLeading)
    }
  }

  #Preview("Output Active") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .ocrVision, internalID: 10),
      isOutputActive: true)
    @Bindable var boundStore = stateService
    if let vision = $boundStore.ocrVision(internalID: 10) {
      OcrVisionInspector(
        stateService: stateService, vision: vision
      )
      .frame(width: 480, height: 800, alignment: .topLeading)
    }
  }

#endif
