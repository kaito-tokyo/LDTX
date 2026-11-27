// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Outlines the selected Video Layer on the preview and lets the pointer move it
/// or scale it from a corner. The Placement fields remain the accessible way to
/// set the same values, so this overlay is hidden from assistive technologies.
struct VideoLayerFrameOverlay: View {
  @Environment(\.undoManager) private var undoManager
  let editor: VideoLayersEditorState
  /// The canvas rectangle in this view's space, in points.
  let canvas: CGRect
  @State private var draft: VideoLayerFrame?
  @State private var dragOrigin: VideoLayerFrame?

  private static let handleSize: CGFloat = 8

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear.allowsHitTesting(false)
      if canvas.width > 0, canvas.height > 0, let frame = draft ?? editor.selectedFrame {
        let rect = viewRect(frame.rect)
        Rectangle()
          .fill(Color.clear)
          .contentShape(Rectangle())
          .overlay { outline(isHidden: isSelectedLayerHidden) }
          .frame(width: max(rect.width, 1), height: max(rect.height, 1))
          .offset(x: rect.minX, y: rect.minY)
          .gesture(moveGesture)
        ForEach(VideoLayerFrame.Corner.allCases, id: \.self) { corner in
          let point = cornerPoint(corner, of: rect)
          Rectangle()
            .fill(.white)
            .strokeBorder(Color.accentColor, lineWidth: 1)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
            .gesture(resizeGesture(corner))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .coordinateSpace(.named(Self.space))
    // Let corner handles at the canvas edge show in full without reaching the editors.
    .clipShape(Rectangle().inset(by: -Self.handleSize / 2))
    .accessibilityHidden(true)
    .onChange(of: editor.selectedLayerID) { _, _ in endDrag() }
  }

  private static let space = "VideoLayerFrameOverlay"

  private var isSelectedLayerHidden: Bool {
    editor.selectedLayerID.flatMap { editor.preferences.videoLayerHidden[$0] } ?? false
  }

  @ViewBuilder private func outline(isHidden: Bool) -> some View {
    let dash: [CGFloat] = isHidden ? [4, 3] : []
    ZStack {
      Rectangle().strokeBorder(.black.opacity(0.6), style: StrokeStyle(lineWidth: 3, dash: dash))
      Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: dash))
    }
  }

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
      .onChanged { value in
        guard let origin = beginDrag() else { return }
        draft = origin.moved(
          dx: value.translation.width / canvas.width,
          dy: value.translation.height / canvas.height)
      }
      .onEnded { _ in commitDrag() }
  }

  private func resizeGesture(_ corner: VideoLayerFrame.Corner) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { value in
        guard let origin = beginDrag() else { return }
        let point = CGPoint(
          x: (value.location.x - canvas.minX) / canvas.width,
          y: (value.location.y - canvas.minY) / canvas.height)
        draft = origin.resized(
          corner: corner, to: point,
          keepsAspectRatio: NSEvent.modifierFlags.contains(.shift))
      }
      .onEnded { _ in commitDrag() }
  }

  private func beginDrag() -> VideoLayerFrame? {
    if dragOrigin == nil { dragOrigin = editor.selectedFrame }
    return dragOrigin
  }

  private func commitDrag() {
    if let draft, draft != dragOrigin {
      editor.commitSelectedFrame(draft, undoManager: undoManager)
    }
    endDrag()
  }

  private func endDrag() {
    draft = nil
    dragOrigin = nil
  }

  private func viewRect(_ rect: CGRect) -> CGRect {
    CGRect(
      x: canvas.minX + rect.minX * canvas.width,
      y: canvas.minY + rect.minY * canvas.height,
      width: rect.width * canvas.width,
      height: rect.height * canvas.height)
  }

  private func cornerPoint(_ corner: VideoLayerFrame.Corner, of rect: CGRect) -> CGPoint {
    switch corner {
    case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
    case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
    case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
    case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
    }
  }
}
