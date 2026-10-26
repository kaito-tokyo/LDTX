// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import CoreGraphics

public struct ProgramPairPreviewRegions {
  public let landscape: CGRect
  public let portrait: CGRect
  public let gap: CGRect

  public init(drawable: CGSize, landscapeSize: CGSize, portraitSize: CGSize) {
    let landscapeRatio = max(1, landscapeSize.width) / max(1, landscapeSize.height)
    let portraitRatio = max(1, portraitSize.width) / max(1, portraitSize.height)
    let gapWidth = min(4, max(0, floor(drawable.width)))
    let availableWidth = max(0, drawable.width - gapWidth)
    let height = floor(
      max(0, min(drawable.height, availableWidth / (landscapeRatio + portraitRatio))))
    let landscapeWidth = floor(height * landscapeRatio)
    let portraitWidth = floor(height * portraitRatio)
    let totalWidth = landscapeWidth + gapWidth + portraitWidth
    let x = floor((drawable.width - totalWidth) / 2)
    let y = floor((drawable.height - height) / 2)
    landscape = CGRect(x: x, y: y, width: landscapeWidth, height: height)
    gap = CGRect(x: x + landscapeWidth, y: y, width: gapWidth, height: height)
    portrait = CGRect(x: gap.maxX, y: y, width: portraitWidth, height: height)
  }
}
