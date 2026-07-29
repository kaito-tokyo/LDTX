// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Observation

@MainActor
@Observable
public final class OutputCanvasModel {
  public struct CanvasSize: Equatable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }
  }

  public struct State: Equatable {
    public var canvasSize: CanvasSize
    public var programDefinitionFrameRate: Int
    public var videoBitRate: Int

    public init(
      canvasSize: CanvasSize,
      programDefinitionFrameRate: Int,
      videoBitRate: Int
    ) {
      self.canvasSize = canvasSize
      self.programDefinitionFrameRate = programDefinitionFrameRate
      self.videoBitRate = videoBitRate
    }
  }

  public static let supportedCanvasSizes: [CanvasSize] = [
    CanvasSize(width: 1_280, height: 720),
    CanvasSize(width: 1_920, height: 1_080),
  ]

  public var canvasSize: CanvasSize
  public var programDefinitionFrameRate: Int
  public var videoBitRate: Int

  public init(
    canvasSize: CanvasSize = CanvasSize(width: 1_920, height: 1_080),
    programDefinitionFrameRate: Int = 60, videoBitRate: Int = 6_000_000
  ) {
    self.canvasSize = canvasSize
    self.programDefinitionFrameRate = programDefinitionFrameRate
    self.videoBitRate = videoBitRate
  }

  public var state: State {
    State(
      canvasSize: canvasSize,
      programDefinitionFrameRate: programDefinitionFrameRate,
      videoBitRate: videoBitRate
    )
  }

  public func applying(to composite: CompositeProgramDefinition) -> CompositeProgramDefinition {
    return composite
  }
}
