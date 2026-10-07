// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXInternalProtocols

/// On-demand rendering using the same component pipeline as Program output.
/// Renderer state is confined to this serial queue, independently of preview consumers.
public final class VideoComponentFrameRenderer: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.component-analysis", qos: .userInitiated)
  private let coordinator: WorkspaceCaptureSessionCoordinator
  private let factory: BackgroundRemovalPreprocessorFactory?
  private let registry: LowFrequencyUpdateRegistry
  private var renderers: [UInt64: ActiveProgramRenderer] = [:]

  public init(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) {
    coordinator = captureSessionCoordinator
    factory = backgroundRemovalPreprocessorFactory
    registry = lowFrequencyUpdateRegistry
  }

  public func render(componentID: UInt64, configuration: ProgramRuntimeConfiguration) async throws
    -> ProgramFrame
  {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          let renderer: ActiveProgramRenderer
          if let existing = renderers[componentID] {
            renderer = existing
          } else {
            renderer = ActiveProgramRenderer(
              captureSessionCoordinator: coordinator,
              backgroundRemovalPreprocessorFactory: factory,
              lowFrequencyUpdateRegistry: registry)
            renderer.beginSession(1)
            renderers[componentID] = renderer
          }
          continuation.resume(
            returning: try renderer.render(
              configuration: configuration, sessionID: 1, frameID: 0))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func retainComponents(_ ids: Set<UInt64>) {
    queue.async { [self] in
      for id in Array(renderers.keys) where !ids.contains(id) {
        renderers.removeValue(forKey: id)?.endSession(1)
      }
    }
  }
}
