// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct CreateMlImageClassifierVisionInspector: View {
  let videoComponents: [Ldtx_Workspace_V4_VideoComponentWrapper]
  let inputSize: (width: UInt32, height: UInt32)?
  @Binding var vision: Ldtx_Workspace_V4_CreateMlImageClassifierVision
  @Binding var modelURL: URL?
  let savedModelURL: URL?
  var inferenceResult: String? = nil
  var inferenceFailure: String? = nil

  @Environment(\.outputActive) var outputActive

  var body: some View {
    Form {
      Section("Vision - Create ML Image Classifier") {
        TextField("Name", text: $vision.displayName)
        VisionInputVideoComponentDropdown(
          videoComponents: videoComponents, selection: $vision.videoComponentInternalIDIfPresent,
          title: "Input video")
        LabeledContent("Model") {
          ModelPathPicker(
            fileURL: $modelURL)
        }
        TriggerEditor(triggers: $vision.triggers)
      }
      .disabled(outputActive)
      Section("Region of Interest") {
        if let inputSize {
          RegionOfInterestEditor(inputSize: inputSize, roi: $vision.regionOfInterest)
        } else {
          Text("Select an input video to edit the region of interest.")
        }
      }
      .disabled(outputActive)
      Section("Inference") {
        if let inferenceFailure { Text(inferenceFailure).foregroundStyle(.red) }
        if let inferenceResult {
          Text(inferenceResult.isEmpty ? "No classifications returned." : inferenceResult)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
  }
}

#if DEBUG
  #Preview {
    @Previewable @State var modelURL: URL?
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

    CreateMlImageClassifierVisionInspector(
      videoComponents: [videoComponent],
      inputSize: vision.videoComponentInternalIDIfPresent == 7 ? videoComponent.renderingSize : nil,
      vision: $vision, modelURL: $modelURL, savedModelURL: nil)
  }
#endif
