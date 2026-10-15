// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import MetalKit
import SwiftUI

/// Application-owned views, registered for exactly one Workspace runtime each.
@MainActor
public final class WorkspaceMetalViews {
  private var views: [UUID: MTKView] = [:]

  public init() {}

  public func acquire(for id: UUID, device: MTLDevice?) -> MTKView {
    precondition(views[id] == nil, "A Workspace already owns a preview view")
    let view = MTKView(frame: .zero, device: device)
    view.isPaused = true
    views[id] = view
    return view
  }

  public func release(for id: UUID) {
    guard let view = views.removeValue(forKey: id) else { return }
    view.isPaused = true
    view.delegate = nil
    view.removeFromSuperview()
  }
}

private struct WorkspaceMetalViewsKey: EnvironmentKey {
  static let defaultValue: WorkspaceMetalViews? = nil
}

extension EnvironmentValues {
  public var workspaceMetalViews: WorkspaceMetalViews? {
    get { self[WorkspaceMetalViewsKey.self] }
    set { self[WorkspaceMetalViewsKey.self] = newValue }
  }
}
