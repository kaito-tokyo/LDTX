// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import LDTXCorelibs

/// The placement of one Video Layer on its canvas, in fractions of the canvas size.
///
/// The origin is the layer's translation and the size is signed, matching how the
/// compositor places a layer: a negative size extends left or up from the origin
/// and mirrors the content.
struct VideoLayerFrame: Equatable {
  enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
  }

  var x: Double
  var y: Double
  var width: Double
  var height: Double
  /// The unsigned size the layer has at scale 1.
  let baseWidth: Double
  let baseHeight: Double

  /// Returns nil for kinds whose size is only known to the renderer, such as Clock.
  init?(
    component: Ldtx_Workspace_V4_VideoComponentWrapper.VideoComponent?,
    transform: Ldtx_Workspace_V4_BasicTransform,
    canvasWidth: Double, canvasHeight: Double
  ) {
    guard canvasWidth > 0, canvasHeight > 0 else { return nil }
    switch component {
    case .vfxSource:
      let left = Self.unit(transform.leftInset?.double ?? 0)
      let right = Self.unit(transform.rightInset?.double ?? 0)
      let top = Self.unit(transform.topInset?.double ?? 0)
      let bottom = Self.unit(transform.bottomInset?.double ?? 0)
      baseWidth = max(0, 1 - left - right)
      baseHeight = max(0, 1 - top - bottom)
    case .dynamicText(let text):
      // Dynamic Text sizes are relative to the 1920x1080 Landscape canvas.
      baseWidth = abs(text.width?.double ?? 0) * 1_920 / canvasWidth
      baseHeight = abs(text.height?.double ?? 0) * 1_080 / canvasHeight
    default:
      return nil
    }
    guard baseWidth > 0, baseHeight > 0 else { return nil }
    x = Self.unit(transform.translationX?.double ?? 0)
    y = Self.unit(transform.translationY?.double ?? 0)
    width = baseWidth * (transform.scaleX?.double ?? 1)
    height = baseHeight * (transform.scaleY?.double ?? 1)
  }

  /// The visible rectangle in fractions of the canvas, with a non-negative size.
  var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height).standardized
  }

  /// Moves the origin by the given fractions; the compositor accepts origins in [0, 1].
  func moved(dx: Double, dy: Double) -> Self {
    var frame = self
    frame.x = Self.unit(x + dx)
    frame.y = Self.unit(y + dy)
    return frame
  }

  /// Moves one visible corner to `point` while the opposite corner stays fixed.
  ///
  /// The layer keeps its mirroring: a corner cannot cross the opposite one. When
  /// `keepsAspectRatio` is true, the larger change decides a uniform scale.
  func resized(
    corner: Corner, to point: CGPoint, keepsAspectRatio: Bool, minimumSize: Double = 0.005
  ) -> Self {
    let visible = rect
    let movesLeft = corner == .topLeft || corner == .bottomLeft
    let movesTop = corner == .topLeft || corner == .topRight
    let anchorX = movesLeft ? visible.maxX : visible.minX
    let anchorY = movesTop ? visible.maxY : visible.minY
    // The origin must stay in [0, 1], so limit the size when the corner moves the origin.
    let originMovesX = (width >= 0) == movesLeft
    let originMovesY = (height >= 0) == movesTop
    let maximumWidth = originMovesX ? (movesLeft ? anchorX : 1 - anchorX) : .infinity
    let maximumHeight = originMovesY ? (movesTop ? anchorY : 1 - anchorY) : .infinity
    var newWidth = max(minimumSize, movesLeft ? anchorX - point.x : point.x - anchorX)
    var newHeight = max(minimumSize, movesTop ? anchorY - point.y : point.y - anchorY)
    if keepsAspectRatio, visible.width > 0, visible.height > 0 {
      let factor = min(
        max(newWidth / visible.width, newHeight / visible.height),
        maximumWidth / visible.width, maximumHeight / visible.height)
      newWidth = visible.width * factor
      newHeight = visible.height * factor
    } else {
      newWidth = min(newWidth, maximumWidth)
      newHeight = min(newHeight, maximumHeight)
    }
    let minX = movesLeft ? anchorX - newWidth : anchorX
    let minY = movesTop ? anchorY - newHeight : anchorY
    var frame = self
    // The origin is the left edge for a positive width and the right edge when mirrored.
    frame.width = width < 0 ? -newWidth : newWidth
    frame.height = height < 0 ? -newHeight : newHeight
    frame.x = Self.unit(width < 0 ? minX + newWidth : minX)
    frame.y = Self.unit(height < 0 ? minY + newHeight : minY)
    return frame
  }

  /// Writes this frame into `transform`, rounding positions to whole canvas pixels
  /// and scales to three decimal places, as the Placement fields display them.
  func applied(
    to transform: Ldtx_Workspace_V4_BasicTransform, canvasWidth: Int, canvasHeight: Int
  ) -> Ldtx_Workspace_V4_BasicTransform {
    var result = transform
    result.translationX = Self.pixels(x, size: canvasWidth)
    result.translationY = Self.pixels(y, size: canvasHeight)
    result.scaleX = .init(value: Self.scale(width / baseWidth))
    result.scaleY = .init(value: Self.scale(height / baseHeight))
    return result
  }

  private static func unit(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
  }

  private static func pixels(_ fraction: Double, size: Int) -> Ldtx_Workspace_V4_Rational32 {
    var value = Ldtx_Workspace_V4_Rational32()
    let size = max(size, 1)
    value.set(num: Int32((fraction * Double(size)).rounded()), den: UInt32(size))
    return value
  }

  private static func scale(_ scale: Double) -> Ldtx_Workspace_V4_Rational32 {
    var value = Ldtx_Workspace_V4_Rational32()
    let thousandths = (scale * 1_000).rounded()
    guard thousandths.isFinite, let num = Int32(exactly: thousandths) else {
      value.set(num: 1, den: 1)
      return value
    }
    value.set(num: num, den: 1_000)
    return value
  }
}
