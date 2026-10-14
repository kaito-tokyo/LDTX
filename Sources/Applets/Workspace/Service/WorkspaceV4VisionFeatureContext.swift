// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel

@MainActor
public struct WorkspaceV4VisionFeatureContext {
  public var vision: (Int64) -> Ldtx_Workspace_V4_OcrVision?
  public var frameForVision:
    (Ldtx_Workspace_V4_OcrVision) async throws -> WorkspaceVisionAnalysisFrame
  public var reportResult: (Int64, String) -> Void
  public var reportFailure: (Int64, Error) -> Void
  public var archiveResult: ((Int64, CIImage, String) -> Void)?
  public var recordingTimelineMilliseconds: (() -> UInt64?)?
  public var sceneDetector: (Int64) -> Ldtx_Workspace_V4_LdtxSceneDetectorVision? = { _ in nil }
  public var modelURL: (Int64) -> URL? = { _ in nil }
  public var isOutputActive: () -> Bool = { false }
  public var reportModelPrepared: (Int64) -> Void = { _ in }
  public var reportPreparationRecovered: (Int64) -> Void = { _ in }
  public var videoComponents: [Ldtx_Workspace_V4_VideoComponentWrapper] = []
  public var frameForSceneDetector:
    ((Ldtx_Workspace_V4_LdtxSceneDetectorVision) async throws -> WorkspaceVisionAnalysisFrame)?

  public init(
    vision: @escaping (Int64) -> Ldtx_Workspace_V4_OcrVision?,
    frameForVision:
      @escaping (Ldtx_Workspace_V4_OcrVision) async throws -> WorkspaceVisionAnalysisFrame,
    reportResult: @escaping (Int64, String) -> Void,
    reportFailure: @escaping (Int64, Error) -> Void,
    archiveResult: ((Int64, CIImage, String) -> Void)? = nil,
    recordingTimelineMilliseconds: (() -> UInt64?)? = nil
  ) {
    self.vision = vision
    self.frameForVision = frameForVision
    self.reportResult = reportResult
    self.reportFailure = reportFailure
    self.archiveResult = archiveResult
    self.recordingTimelineMilliseconds = recordingTimelineMilliseconds
  }
}

public struct WorkspaceVisionAnalysisFrame: @unchecked Sendable {
  public let image: CIImage
  public init(image: CIImage) { self.image = image }
}

public enum WorkspaceVisionFeatureError: Error, LocalizedError, Equatable, Sendable {
  case referencedVideoComponentMissing
  case vfxSourceHasNoPhysicalCamera
  case frameUnavailable

  public var errorDescription: String? {
    switch self {
    case .referencedVideoComponentMissing: "The referenced Video Component is unavailable."
    case .vfxSourceHasNoPhysicalCamera:
      "Assign a physical camera to the VFX Source before recognizing text."
    case .frameUnavailable: "The Video Component frame is unavailable or still preparing."
    }
  }
}
