// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct OcrVisionInspector: View {
  let storeService: WorkspaceStoreService
  let internalID: UInt64

  var body: some View {
    Form {
      formContent
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    if let vision {
      Section("OCR Vision") {
        TextField("Name", text: visionBinding(\.displayName, initial: vision.displayName))
          .disabled(isRecording)
        WorkspaceSelectionField(
          title: "Video Component", current: sourceBinding.wrappedValue,
          options: videoDevices,
          clearTitle: "Remove Assignment", isEditable: !isRecording,
          reportError: { storeService.reportError($0) },
          commit: { selected in
            guard !isRecording, self.vision != nil,
              selected == nil || videoDevices.contains(where: { $0.id == selected })
            else {
              throw WorkspaceSelectionError(
                message: "The input or Vision is no longer available for editing.")
            }
            sourceBinding.wrappedValue = selected
            storeService.synchronizeVision()
          })
        Picker("Update Interval", selection: intervalBinding) {
          Text("Manual").tag(0.0)
          Text("Every 1 Second").tag(1.0)
          Text("Every 5 Seconds").tag(5.0)
          Text("Every 10 Seconds").tag(10.0)
          Text("Every 30 Seconds").tag(30.0)
        }
        .disabled(isRecording)
        LabeledContent("Recognition", value: "Accurate")
        Toggle(
          "Language Correction",
          isOn: visionBinding(\.usesLanguageCorrection, initial: vision.usesLanguageCorrection)
        )
        .disabled(isRecording)
        TextField("Languages (comma separated)", text: languagesBinding)
          .disabled(isRecording)
        TextField("Custom Words (comma separated)", text: customWordsBinding)
          .disabled(isRecording)
        LabeledContent("Minimum Text Height") {
          TextField(
            "Fraction", value: minimumTextHeightBinding, format: RationalFormatStyle()
          )
          .multilineTextAlignment(.trailing)
          .frame(width: 90)
        }
        .disabled(isRecording)
      }
      Section("Recognition Result") {
        if let failure = storeService.visionFailureMessages[internalID] {
          Text(failure).foregroundStyle(.red)
        } else if let result = storeService.visionResults[internalID] {
          Text(result.isEmpty ? "No text recognized." : result).textSelection(.enabled)
        } else {
          Text("Waiting for recognition.").foregroundStyle(.secondary)
        }
      }
      Section("Region of Interest") {
        regionField("X", keyPath: \.x, initial: vision.regionOfInterest.x)
        regionField("Y", keyPath: \.y, initial: vision.regionOfInterest.y)
        regionField(
          "Width", keyPath: \.width,
          initial: vision.regionOfInterest.width)
        regionField(
          "Height", keyPath: \.height,
          initial: vision.regionOfInterest.height)
        Text("Coordinates are normalized from 0 to 1.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      Section("OCR Vision") {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }

  }

  private var vision: Ldtx_Workspace_V4_OcrVision? {
    storeService.definition.visions.compactMap { wrapper -> Ldtx_Workspace_V4_OcrVision? in
      guard case .ocrVision(let vision) = wrapper.vision,
        vision.internalID == internalID
      else { return nil }
      return vision
    }.first
  }

  private var videoDevices: [WorkspaceSelectionOption<UInt64>] {
    storeService.videoComponentOptions
  }

  private var isRecording: Bool { storeService.isOutputActive }

  private func visionBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_OcrVision, Value>, initial: Value
  ) -> Binding<Value> {
    Binding(
      get: { vision?[keyPath: keyPath] ?? initial },
      set: { next in editVision { $0[keyPath: keyPath] = next } }
    )
  }

  private var sourceBinding: Binding<UInt64?> {
    Binding(
      get: {
        guard let sourceID = vision?.videoComponentInternalID, sourceID != 0 else { return nil }
        return sourceID
      },
      set: { internalID in
        editVision { value in
          if let internalID {
            value.videoComponentInternalID = internalID
          } else {
            value.clearVideoComponentInternalID()
          }
        }
      }
    )
  }

  private var intervalBinding: Binding<Double> {
    Binding(
      get: {
        vision?.triggers.first.flatMap { wrapper in
          guard case .intervalTrigger(let value) = wrapper.trigger else { return nil }
          return value.intervalSeconds.double
        } ?? 0
      },
      set: { interval in
        editVision { value in
          value.triggers.removeAll()
          guard interval > 0 else { return }
          var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
          trigger.intervalSeconds =
            (try? RationalParseStrategy().parse(String(interval))) ?? .init()
          var wrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
          wrapper.trigger = .intervalTrigger(trigger)
          value.triggers.append(wrapper)
        }
      }
    )
  }

  private var languagesBinding: Binding<String> {
    Binding(
      get: { vision?.recognitionLanguages.joined(separator: ", ") ?? "" },
      set: { text in
        editVision {
          $0.recognitionLanguages = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }.filter { !$0.isEmpty }
        }
      }
    )
  }

  private var customWordsBinding: Binding<String> {
    Binding(
      get: { vision?.customWords.joined(separator: ", ") ?? "" },
      set: { text in
        editVision {
          $0.customWords = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }.filter { !$0.isEmpty }
        }
      }
    )
  }

  private var minimumTextHeightBinding: Binding<Ldtx_Workspace_V4_Rational32> {
    Binding(
      get: {
        vision?.minimumTextHeight ?? .init()
      },
      set: { next in editVision { $0.minimumTextHeight = next } }
    )
  }

  private func regionField<Value: Rational32Value>(
    _ title: String,
    keyPath: WritableKeyPath<
      Ldtx_Workspace_V4_VisionRegionOfInterest, Value
    >,
    initial: Value
  ) -> some View {
    LabeledContent(title) {
      TextField(
        title,
        text: Binding(
          get: {
            storeService.ocrRegionDrafts[internalID]?[title]
              ?? RationalValueFormatStyle<Value>().format(initial)
          },
          set: { storeService.editOcrRegion(internalID: internalID, field: title, text: $0) })
      )
      .multilineTextAlignment(.trailing)
      .frame(width: 90)
      .disabled(isRecording)
    }
  }

  private func editVision(_ mutation: (inout Ldtx_Workspace_V4_OcrVision) -> Void) {
    var definition = storeService.definition
    guard
      let index = definition.visions.firstIndex(where: { wrapper in
        guard case .ocrVision(let value) = wrapper.vision else { return false }
        return value.internalID == internalID
      }), case .ocrVision(var value) = definition.visions[index].vision
    else { return }
    mutation(&value)
    definition.visions[index].vision = .ocrVision(value)
    storeService.definition = definition
  }
}
