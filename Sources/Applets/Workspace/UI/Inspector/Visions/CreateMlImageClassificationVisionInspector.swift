// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import SwiftUI

struct LdtxSceneDetectorVisionInspector: View {
  let videoComponents: [Ldtx_Workspace_V4_VideoComponentWrapper]
  let inputSize: (width: UInt32, height: UInt32)?
  @Binding var vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision
  @Binding var modelURL: URL?
  var persistedModelURL: URL? = nil
  var inferenceResult: String? = nil
  var inferenceFailure: String? = nil
  var modelPreparationGeneration: UInt64 = 0

  @Environment(\.outputActive) var outputActive
  var readModelInformation: (URL) async throws -> WorkspaceVisionModelInformation = { _ in
    throw CocoaError(.featureUnsupported)
  }
  @State private var modelInformation: WorkspaceVisionModelInformation?
  @State private var modelInformationFailure: String?

  var modelInformationURL: URL? { persistedModelURL ?? modelURL }

  var body: some View {
    Form {
      Section("Vision - Create ML Image Classifier") {
        TextField("Name", text: $vision.displayName.defaulting(to: ""))
        VisionInputVideoComponentDropdown(
          videoComponents: videoComponents, selection: $vision.videoComponentInternalIDIfPresent,
          title: "Input video", requiresPositiveSize: true)
        LabeledContent("Model") {
          ModelPathPicker(
            fileURL: $modelURL)
        }
        TriggerEditor(triggers: $vision.triggers)
      }
      .disabled(outputActive)
      if modelInformationURL != nil {
        Section("Model Information") {
          if let modelInformation {
            LabeledContent(
              "Crop and Scale", value: String(localized: cropAndScaleLabel(modelInformation)))
            if let width = modelInformation.inputWidth, let height = modelInformation.inputHeight {
              LabeledContent("Model Input Size", value: "\(width) × \(height)")
            }
            if let author = modelInformation.author, !author.isEmpty {
              LabeledContent("Author", value: author)
            }
            if let description = modelInformation.description, !description.isEmpty {
              Text(description).textSelection(.enabled)
            }
          } else if let modelInformationFailure {
            Text(modelInformationFailure).foregroundStyle(.secondary)
          } else {
            ProgressView("Loading model information…")
          }
        }
      }
      Section("Region of Interest") {
        if let inputSize {
          RegionOfInterestEditor(
            inputSize: inputSize, roi: $vision.regionOfInterest.defaulting(to: .init()))
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
    .task(
      id: ModelInformationRequest(
        url: modelInformationURL, noCompile: outputActive,
        preparationGeneration: modelPreparationGeneration)
    ) {
      modelInformation = nil
      modelInformationFailure = nil
      guard let url = modelInformationURL else { return }
      let noCompile = outputActive
      let generation = modelPreparationGeneration
      do {
        let information = try await readModelInformation(url)
        guard modelInformationURL == url, outputActive == noCompile,
          modelPreparationGeneration == generation
        else { return }
        modelInformation = information
      } catch {
        guard modelInformationURL == url, outputActive == noCompile,
          modelPreparationGeneration == generation
        else { return }
        modelInformationFailure = error.localizedDescription
      }
    }
  }

  private struct ModelInformationRequest: Equatable {
    let url: URL?
    let noCompile: Bool
    let preparationGeneration: UInt64
  }

  private func cropAndScaleLabel(
    _ information: WorkspaceVisionModelInformation
  ) -> LocalizedStringResource {
    switch information.cropAndScaleAction {
    case .centerCrop: "Center Crop"
    case .scaleToFit: "Scale to Fit"
    case .scaleToFill: "Scale to Fill"
    case .scaleToFitPlus90CCWRotation: "Scale to Fit + 90° CCW"
    case .scaleToFillPlus90CCWRotation: "Scale to Fill + 90° CCW"
    @unknown default: "Center Crop"
    }
  }
}

#if DEBUG
  #Preview {
    @Previewable @State var modelURL: URL?
    @Previewable @State var vision =
      Ldtx_Workspace_V4_LdtxSceneDetectorVision.with {
        $0.videoComponentInternalID = 7
      }

    let videoComponent = Ldtx_Workspace_V4_VideoComponentWrapper.with {
      $0.videoComponent = .vfxSource(
        .with {
          $0.internalID = 7
          $0.displayName = "Camera"
          $0.deviceWidth = 1920
          $0.deviceHeight = 1080
        })
    }

    LdtxSceneDetectorVisionInspector(
      videoComponents: [videoComponent],
      inputSize: vision.videoComponentInternalIDIfPresent == 7 ? videoComponent.renderingSize : nil,
      vision: $vision, modelURL: $modelURL)
  }
#endif
