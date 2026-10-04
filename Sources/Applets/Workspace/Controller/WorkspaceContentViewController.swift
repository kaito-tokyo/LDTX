// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletUI
import MetalKit

final class WorkspaceContentViewController: NSSplitViewController {
  private let previewDelegate: any MTKViewDelegate
  let preview: ProgramCanvasPairedPreview
  private let initialRatio: Double?
  private let saveRatio: (Double) -> Void
  private var didSetInitialPosition = false

  init(
    preview: ProgramCanvasPairedPreview, delegate: any MTKViewDelegate, editor: NSViewController,
    initialRatio: Double?, saveRatio: @escaping (Double) -> Void
  ) {
    self.previewDelegate = delegate
    self.preview = preview
    self.initialRatio = initialRatio
    self.saveRatio = saveRatio
    super.init(nibName: nil, bundle: nil)
    let split = WorkspaceContentSplitView()
    split.isVertical = false
    split.dividerStyle = .thin
    split.onDividerDragged = { [weak self] in self?.saveDividerPosition() }
    splitView = split
    let previewController = NSViewController()
    previewController.view = preview
    for controller in [previewController, editor] {
      let item = NSSplitViewItem(viewController: controller)
      item.minimumThickness = 100
      item.canCollapse = false
      item.automaticallyAdjustsSafeAreaInsets = false
      addSplitViewItem(item)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard !didSetInitialPosition, splitView.bounds.height >= 200 + splitView.dividerThickness else {
      return
    }
    didSetInitialPosition = true
    let available = splitView.bounds.height - splitView.dividerThickness
    let desired =
      initialRatio.flatMap { $0.isFinite && $0 > 0 && $0 < 1 ? CGFloat($0) * available : nil }
      ?? 280
    splitView.setPosition(min(max(100, desired), available - 100), ofDividerAt: 0)
  }

  func restoreInitialDividerPosition() {
    didSetInitialPosition = false
    viewDidLayout()
  }

  func saveDividerPosition() {
    let available = splitView.bounds.height - splitView.dividerThickness
    guard didSetInitialPosition, available > 0 else { return }
    saveRatio(Double(splitView.arrangedSubviews[0].frame.height / available))
  }
}

private final class WorkspaceContentSplitView: NSSplitView {
  var onDividerDragged: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let isDivider =
      arrangedSubviews.count == 2
      && NSRect(
        x: 0, y: min(arrangedSubviews[0].frame.maxY, arrangedSubviews[1].frame.maxY),
        width: bounds.width, height: dividerThickness
      ).insetBy(dx: 0, dy: -2).contains(point)
    super.mouseDown(with: event)
    if isDivider { onDividerDragged?() }
  }
}
