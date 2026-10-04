// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_BasicTransform {
  public init(translationX: Float, translationY: Float, scaleX: Float, scaleY: Float) {
    self.init()
    self.translationX = translationX
    self.translationY = translationY
    self.scaleX = scaleX
    self.scaleY = scaleY
  }
}
