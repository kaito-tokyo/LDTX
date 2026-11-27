// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite.Shard1 {
  @Suite("Video layer frames on the preview", .serialized) @MainActor
  struct VideoLayerFrameTestSuite {
    private func transform(
      x: Int32 = 0, y: Int32 = 0, scaleX: Double = 1, scaleY: Double = 1,
      leftInset: Double = 0
    ) throws -> Ldtx_Workspace_V4_BasicTransform {
      func rational(_ value: Double) throws -> Ldtx_Workspace_V4_Rational32 {
        var result = Ldtx_Workspace_V4_Rational32()
        try result.set(decimal: Decimal(value))
        return result
      }
      var result = Ldtx_Workspace_V4_BasicTransform()
      var translationX = Ldtx_Workspace_V4_Rational32()
      translationX.set(num: x, den: 1_920)
      var translationY = Ldtx_Workspace_V4_Rational32()
      translationY.set(num: y, den: 1_080)
      result.translationX = translationX
      result.translationY = translationY
      result.scaleX = .init(value: try rational(scaleX))
      result.scaleY = .init(value: try rational(scaleY))
      result.leftInset = try rational(leftInset)
      return result
    }

    private func frame(
      _ component: Ldtx_Workspace_V4_VideoComponentWrapper.VideoComponent?,
      _ transform: Ldtx_Workspace_V4_BasicTransform,
      width: Double = 1_920, height: Double = 1_080
    ) -> VideoLayerFrame? {
      VideoLayerFrame(
        component: component, transform: transform, canvasWidth: width, canvasHeight: height)
    }

    @Test("LUB-1048: Frames follow the compositor's placement for each kind")
    func framesFollowCompositor() throws {
      let camera = try #require(
        frame(.vfxSource(.init()), transform(x: 960, y: 540, scaleX: 0.5, scaleY: 0.25)))
      #expect(camera.rect == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.25))
      let cropped = try #require(frame(.vfxSource(.init()), transform(leftInset: 0.5)))
      #expect(cropped.rect.width == 0.5)
      let mirrored = try #require(frame(.vfxSource(.init()), transform(x: 960, scaleX: -0.5)))
      #expect(mirrored.rect == CGRect(x: 0, y: 0, width: 0.5, height: 1))

      var dynamicText = Ldtx_Workspace_V4_DynamicTextComponent()
      dynamicText.width = Ldtx_Workspace_V4_Rational32()
      dynamicText.width?.set(num: 1, den: 4)
      dynamicText.height = Ldtx_Workspace_V4_Rational32()
      dynamicText.height?.set(num: 1, den: 8)
      let text = Ldtx_Workspace_V4_VideoComponentWrapper.VideoComponent.dynamicText(dynamicText)
      #expect(
        try #require(frame(text, transform())).rect.size == CGSize(width: 0.25, height: 0.125))
      let portrait = try #require(frame(text, transform(), width: 1_080, height: 1_920))
      #expect(abs(portrait.rect.width - 0.25 * 1_920 / 1_080) < 1e-9)
      #expect(abs(portrait.rect.height - 0.125 * 1_080 / 1_920) < 1e-9)

      #expect(try frame(.clock(.init()), transform()) == nil)
      #expect(try frame(nil, transform()) == nil)
      #expect(try frame(.vfxSource(.init()), transform(leftInset: 1)) == nil)
    }

    @Test("LUB-1048: Moving keeps the origin inside the canvas")
    func movingClampsOrigin() throws {
      let start = try #require(frame(.vfxSource(.init()), transform(x: 960, scaleX: 0.5)))
      #expect(start.moved(dx: 0.25, dy: 0.1).rect.origin == CGPoint(x: 0.75, y: 0.1))
      #expect(start.moved(dx: 2, dy: -1).rect.origin == CGPoint(x: 1, y: 0))
    }

    @Test("LUB-1048: Corner resizing keeps the opposite corner and the mirroring")
    func cornerResizing() throws {
      let start = try #require(
        frame(.vfxSource(.init()), transform(x: 480, y: 270, scaleX: 0.5, scaleY: 0.5)))
      let free = start.resized(
        corner: .bottomRight, to: CGPoint(x: 1, y: 0.5), keepsAspectRatio: false)
      #expect(free.rect == CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.25))
      let uniform = start.resized(
        corner: .bottomRight, to: CGPoint(x: 1, y: 0.5), keepsAspectRatio: true)
      #expect(uniform.rect == CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.75))
      let fromTopLeft = start.resized(
        corner: .topLeft, to: CGPoint(x: -0.5, y: 0.5), keepsAspectRatio: false)
      #expect(fromTopLeft.rect.minX == 0)
      #expect(fromTopLeft.rect.maxX == 0.75)
      #expect(fromTopLeft.rect.minY == 0.5)

      let mirrored = try #require(
        frame(.vfxSource(.init()), transform(x: 1_440, scaleX: -0.5)))
      let wider = mirrored.resized(
        corner: .topLeft, to: CGPoint(x: 0, y: 0), keepsAspectRatio: false)
      #expect(wider.width < 0)
      #expect(wider.rect == CGRect(x: 0, y: 0, width: 0.75, height: 1))
    }

    @Test("LUB-1048: A dragged frame saves rounded values as one Undo step")
    func committingDraggedFrame() throws {
      let fixture = VideoLayersTestFixture()
      let undoManager = UndoManager()
      undoManager.groupsByEvent = false
      fixture.editor.selectedLayerID = 2
      let start = try #require(fixture.editor.selectedFrame)
      undoManager.beginUndoGrouping()
      fixture.editor.commitSelectedFrame(
        start.moved(dx: 0.25, dy: 0.5)
          .resized(
            corner: .bottomRight, to: CGPoint(x: 0.6251, y: 0.75), keepsAspectRatio: false),
        undoManager: undoManager)
      undoManager.endUndoGrouping()
      let saved = try #require(fixture.editor.preferences.videoLayerTransforms[2])
      #expect(saved.translationX?.num == 480)
      #expect(saved.translationX?.den == 1_920)
      #expect(saved.translationY?.num == 540)
      #expect(saved.scaleX?.double == 0.375)
      #expect(saved.scaleY?.double == 0.25)
      #expect(fixture.editor.rows[2]?.strings == ["480", "540", "0.375", "0.25"])
      undoManager.undo()
      #expect(fixture.editor.preferences.videoLayerTransforms[2] == nil)

      fixture.editor.selectedLayerID = nil
      fixture.editor.commitSelectedFrame(start.moved(dx: 0.5, dy: 0))
      #expect(fixture.editor.preferences.videoLayerTransforms[2] == nil)
    }
  }
}
