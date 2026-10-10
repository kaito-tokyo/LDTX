// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct CreateMlImageClassifierVisionInspector: View {
  var videoComponents: [Ldtx_Workspace_V4_VideoComponentWrapper]
  @Binding var vision: Ldtx_Workspace_V4_CreateMlImageClassifierVision

  @Environment(\.outputActive) var outputActive

  private func rationalTextField<Value: Rational32Value>(
    value: Binding<Value>,
    numeratorPrompt: Text?,
    denominatorPrompt: Text?,
    numeratorLabel: LocalizedStringResource,
    denominatorLabel: LocalizedStringResource
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      TextField(
        numeratorLabel,
        value: value.numIfPresent,
        formatter: NullableIntegerFormatter<Int32>(),
        prompt: numeratorPrompt
      )
      .frame(width: 50)
      Text("/")
      TextField(
        denominatorLabel,
        value: value.denIfPresent,
        formatter: NullableIntegerFormatter<UInt32>(),
        prompt: denominatorPrompt
      )
      .frame(width: 50)
    }
    .labelsHidden()
  }

  var body: some View {
    let visionInputOptions: [(Int64?, String?)] = videoComponents.enumerated().compactMap {
      $1.canBeVisionInput ? (id: $1.internalID ?? -Int64($0 + 1), name: $1.displayName) : nil
    }

    Form {
      Section("Vision - Create ML Image Classifier") {
        TextField("Name", text: $vision.displayName)
        Picker("Input video", selection: $vision.videoComponentInternalIDIfPresent) {
          Text("Unassigned").tag(Int64?.none)
          ForEach(visionInputOptions, id: \.0) { (id, name) in
            if let name {
              Text(name).tag(id)
            } else {
              Text("(invalid video component)").tag(id)
            }
          }
        }
        Picker("Update Interval", selection: $vision.triggers) {
          Text("Manual").tag([Ldtx_Workspace_V4_VisionTriggerWrapper]())
          Text("Every 1 Second").tag([intervalTrigger(seconds: 1)])
          Text("Every 5 Seconds").tag([intervalTrigger(seconds: 5)])
          Text("Every 10 Seconds").tag([intervalTrigger(seconds: 10)])
          Text("Every 30 Seconds").tag([intervalTrigger(seconds: 30)])
        }
      }
      .disabled(outputActive)
      Section("Region of Interest") {
        LabeledContent("X") {
          rationalTextField(
            value: $vision.regionOfInterest.x,
            numeratorPrompt: Text("0"),
            denominatorPrompt: inputSize.map { Text(String($0.width)) },
            numeratorLabel: "X numerator", denominatorLabel: "X denominator")
        }
        LabeledContent("Y") {
          rationalTextField(
            value: $vision.regionOfInterest.y,
            numeratorPrompt: Text("0"),
            denominatorPrompt: inputSize.map { Text(String($0.height)) },
            numeratorLabel: "Y numerator", denominatorLabel: "Y denominator")
        }
        LabeledContent("Width") {
          rationalTextField(
            value: $vision.regionOfInterest.width,
            numeratorPrompt: inputSize.map { Text(String($0.width)) },
            denominatorPrompt: inputSize.map { Text(String($0.width)) },
            numeratorLabel: "Width numerator", denominatorLabel: "Width denominator")
        }
        LabeledContent("Height") {
          rationalTextField(
            value: $vision.regionOfInterest.height,
            numeratorPrompt: inputSize.map { Text(String($0.height)) },
            denominatorPrompt: inputSize.map { Text(String($0.height)) },
            numeratorLabel: "Height numerator", denominatorLabel: "Height denominator")
        }
      }
      .disabled(outputActive)
    }
    .formStyle(.grouped)
  }

  var inputSize: (width: UInt32, height: UInt32)? {
    guard let id = vision.videoComponentInternalIDIfPresent else { return nil }
    return videoComponents.first { $0.internalID == id }?.renderingSize
  }

  func intervalTrigger(seconds: Int32) -> Ldtx_Workspace_V4_VisionTriggerWrapper {
    .with { $0.intervalTrigger.intervalSeconds.set(num: seconds, den: 1) }
  }

  static func validatedRegion(
    x: Int32?, y: Int32?, width: Int32?, height: Int32?,
    xDenominator: UInt32? = 1, yDenominator: UInt32? = 1,
    widthDenominator: UInt32? = 1, heightDenominator: UInt32? = 1
  ) throws
    -> Ldtx_Workspace_V4_VisionRegionOfInterest
  {
    do {
      guard let x, let y, let width, let height,
        let xDenominator, let yDenominator, let widthDenominator, let heightDenominator
      else { throw RationalInputError.invalidNumber }
      guard xDenominator > 0, yDenominator > 0, widthDenominator > 0, heightDenominator > 0
      else { throw RationalInputError.zeroDenominator }
      var region = Ldtx_Workspace_V4_VisionRegionOfInterest()
      region.x.set(num: x, den: xDenominator)
      region.y.set(num: y, den: yDenominator)
      region.width.set(num: width, den: widthDenominator)
      region.height.set(num: height, den: heightDenominator)
      try WorkspaceV4IntegrityValidator.validateRegionOfInterest(region)
      return region
    } catch {
      throw WorkspaceSelectionError(
        message: "Correct the classifier ROI before applying changes. "
          + error.localizedDescription)
    }
  }
}

#if DEBUG
  #Preview {
    @Previewable @State var vision =
      Ldtx_Workspace_V4_CreateMlImageClassifierVision.with {
        $0.videoComponentInternalID = 7
      }

    let videoComponent = Ldtx_Workspace_V4_VideoComponentWrapper.with {
      $0.vfxSource.internalID = 7
      $0.vfxSource.displayName = "Camera"
      $0.vfxSource.deviceWidth = 1920
      $0.vfxSource.deviceHeight = 1080
    }

    CreateMlImageClassifierVisionInspector(videoComponents: [videoComponent], vision: $vision)
  }
#endif
