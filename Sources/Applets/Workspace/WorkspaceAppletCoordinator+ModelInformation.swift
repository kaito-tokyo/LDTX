// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXProtos
import LDTXVision

extension WorkspaceAppletCoordinator {
  public func readVisionModelInformation(at url: URL) async throws
    -> WorkspaceVisionModelInformation
  {
    let information = try await VisionImageClassifierService.readModelInformation(at: url)
    let crop: WorkspaceVisionModelInformation.CropAndScale
    switch information.cropAndScaleAction {
    case .centerCrop: crop = .centerCrop
    case .scaleToFit: crop = .scaleToFit
    case .scaleToFill: crop = .scaleToFill
    case .scaleToFitPlus90CCWRotation: crop = .scaleToFitPlus90CCWRotation
    case .scaleToFillPlus90CCWRotation: crop = .scaleToFillPlus90CCWRotation
    @unknown default: crop = .centerCrop
    }
    return WorkspaceVisionModelInformation(
      cropAndScaleAction: crop, description: information.description, author: information.author,
      inputWidth: information.inputWidth, inputHeight: information.inputHeight)
  }
}
