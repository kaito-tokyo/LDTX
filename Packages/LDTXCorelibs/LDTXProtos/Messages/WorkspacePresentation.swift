// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum WorkspaceAudioMaster: Int, CaseIterable, Sendable { case landscape, portrait }

public struct WorkspaceVisionModelInformation: Equatable, Sendable {
  public enum CropAndScale: Equatable, Sendable {
    case centerCrop, scaleToFit, scaleToFill, scaleToFitPlus90CCWRotation,
      scaleToFillPlus90CCWRotation
  }
  public let cropAndScaleAction: CropAndScale
  public let description: String?
  public let author: String?
  public let inputWidth: Int?
  public let inputHeight: Int?

  public init(
    cropAndScaleAction: CropAndScale, description: String? = nil, author: String? = nil,
    inputWidth: Int? = nil, inputHeight: Int? = nil
  ) {
    self.cropAndScaleAction = cropAndScaleAction
    self.description = description
    self.author = author
    self.inputWidth = inputWidth
    self.inputHeight = inputHeight
  }
}
