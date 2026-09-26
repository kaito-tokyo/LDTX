// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct OcrVisionInspector: View {
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let session: (any WorkspaceSessionProtocol)?
  let recordingSession: (any WorkspaceRecordingSessionProtocol)?

  var body: some View {
    if let vision {
      Section("OCR Vision") {
        TextField("Name", text: visionBinding(\.displayName, initial: vision.displayName))
          .disabled(isRecording)
        Picker("Video Input", selection: sourceBinding) {
          Text("No Input Device").tag(nil as UInt64?)
          ForEach(videoDevices, id: \.internalID) { device in
            Text(device.displayName).tag(Optional(device.internalID))
          }
        }
        .disabled(isRecording)
        Picker("Update Interval", selection: intervalBinding) {
          Text("Manual").tag(0.0)
          Text("Every 1 Second").tag(1.0)
          Text("Every 5 Seconds").tag(5.0)
          Text("Every 10 Seconds").tag(10.0)
          Text("Every 30 Seconds").tag(30.0)
        }
        .disabled(isRecording)
        Picker("Recognition", selection: visionBinding(\.accurate, initial: vision.accurate)) {
          Text("Fast").tag(false)
          Text("Accurate").tag(true)
        }
        .disabled(isRecording)
        Toggle(
          "Language Correction",
          isOn: visionBinding(\.usesLanguageCorrection, initial: vision.usesLanguageCorrection)
        )
        .disabled(isRecording)
        TextField("Languages (comma separated)", text: languagesBinding)
          .disabled(isRecording)
        TextField("Custom Words (comma separated)", text: customWordsBinding)
          .disabled(isRecording)
        Toggle("Minimum Text Height", isOn: minimumTextHeightEnabledBinding)
          .disabled(isRecording)
        if vision.hasMinimumTextHeight {
          LabeledContent("Minimum Height") {
            TextField(
              "Fraction", value: minimumTextHeightBinding,
              format: .number.precision(.fractionLength(3))
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
          }
          .disabled(isRecording)
        }
      }
      Section("Region of Interest") {
        regionField("X", keyPath: \.x, initial: vision.regionOfInterest.x)
        regionField("Y", keyPath: \.y, initial: vision.regionOfInterest.y)
        regionField("Width", keyPath: \.width, initial: vision.regionOfInterest.width)
        regionField("Height", keyPath: \.height, initial: vision.regionOfInterest.height)
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
    uiState.definition.visions.compactMap { wrapper -> Ldtx_Workspace_V4_OcrVision? in
      guard case .ocrVision(let vision) = wrapper.definition,
        vision.internalID == internalID
      else { return nil }
      return vision
    }.first
  }

  private var videoDevices: [Ldtx_Workspace_V4_VideoInputDevice] {
    uiState.definition.inputDevices.compactMap { wrapper in
      guard case .videoDevice(let device) = wrapper.definition else { return nil }
      return device
    }
  }

  private var isRecording: Bool { recordingSession?.isRecording ?? false }

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
        if case .inputDeviceInternalID(let value)? = vision?.source { return value }
        return nil
      },
      set: { internalID in
        editVision { value in
          if let internalID { value.inputDeviceInternalID = internalID } else { value.source = nil }
        }
      }
    )
  }

  private var intervalBinding: Binding<Double> {
    Binding(
      get: {
        vision?.triggers.first.flatMap { wrapper in
          guard case .intervalTrigger(let value) = wrapper.definition else { return nil }
          return value.intervalSeconds
        } ?? 0
      },
      set: { interval in
        editVision { value in
          value.triggers.removeAll()
          guard interval > 0 else { return }
          var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
          trigger.intervalSeconds = interval
          var wrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
          wrapper.definition = .intervalTrigger(trigger)
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

  private var minimumTextHeightEnabledBinding: Binding<Bool> {
    Binding(
      get: { vision?.hasMinimumTextHeight ?? false },
      set: { enabled in
        editVision { value in
          if enabled { value.minimumTextHeight = 0.01 } else { value.clearMinimumTextHeight() }
        }
      }
    )
  }

  private var minimumTextHeightBinding: Binding<Float> {
    Binding(
      get: { vision?.minimumTextHeight ?? 0.01 },
      set: { next in editVision { $0.minimumTextHeight = min(max(next, 0), 1) } }
    )
  }

  private func regionField(
    _ title: String,
    keyPath: WritableKeyPath<Ldtx_Workspace_V4_VisionRegionOfInterest, Float>,
    initial: Float
  ) -> some View {
    LabeledContent(title) {
      TextField(
        title, value: regionBinding(keyPath, initial: initial),
        format: .number.precision(.fractionLength(3))
      )
      .multilineTextAlignment(.trailing)
      .frame(width: 90)
      .disabled(isRecording)
    }
  }

  private func regionBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_VisionRegionOfInterest, Float>, initial: Float
  ) -> Binding<Float> {
    Binding(
      get: { vision.map { $0.regionOfInterest[keyPath: keyPath] } ?? initial },
      set: { next in
        editVision { value in
          var region = value.regionOfInterest
          region[keyPath: keyPath] = min(max(next, 0), 1)
          value.regionOfInterest = region
        }
      }
    )
  }

  private func editVision(_ mutation: (inout Ldtx_Workspace_V4_OcrVision) -> Void) {
    var definition = uiState.definition
    guard
      let index = definition.visions.firstIndex(where: { wrapper in
        guard case .ocrVision(let value) = wrapper.definition else { return false }
        return value.internalID == internalID
      }), case .ocrVision(var value) = definition.visions[index].definition
    else { return }
    mutation(&value)
    definition.visions[index].definition = .ocrVision(value)
    uiState.definition = definition
  }
}
