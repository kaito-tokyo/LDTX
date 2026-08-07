// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXVision
import LDTXWorkspace
import SwiftUI

struct VisionModelSettingsView: View {
  @State private var downloadedRepositoryIDs: Set<String> = []
  private let service = VisionModelService()

  private static let downloadGuideURL = URL(
    string: "https://github.com/kaito-tokyo/LDTX/blob/main/docs/download-vlm.md"
  )!

  private let models = [
    ModelOption(name: "Qwen3-VL 2B Instruct (4-bit)", model: .qwen3VL2BInstruct4Bit),
    ModelOption(name: "Qwen3-VL 4B Instruct (4-bit)", model: .qwen3VL4BInstruct4Bit),
  ]

  var body: some View {
    Form {
      Section("Vision Models") {
        ForEach(models) { option in
          LabeledContent(option.name) {
            Text(isDownloaded(option.model) ? "Available" : "Not Found")
              .foregroundStyle(.secondary)
          }
        }
        Link("How to Install Vision Models", destination: Self.downloadGuideURL)
        Text(
          "Vision models run locally and are not sent to an external inference service."
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await refreshDownloadedModels() }
  }

  private func isDownloaded(_ model: WorkspaceVisionModel) -> Bool {
    downloadedRepositoryIDs.contains(model.repositoryID)
  }

  private func refreshDownloadedModels() async {
    var downloadedRepositoryIDs: Set<String> = []
    for option in models where await service.isDownloaded(model: option.model) {
      downloadedRepositoryIDs.insert(option.model.repositoryID)
    }
    guard !Task.isCancelled else { return }
    self.downloadedRepositoryIDs = downloadedRepositoryIDs
  }

  private struct ModelOption: Identifiable {
    var id: String { model.repositoryID }
    let name: String
    let model: WorkspaceVisionModel
  }
}
