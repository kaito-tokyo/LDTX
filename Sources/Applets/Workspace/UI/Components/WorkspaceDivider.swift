// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Resizes along an axis while the owning pane controls bounds and persistence.
public struct WorkspaceDivider: View {
  let title: LocalizedStringKey
  let axis: Axis
  let value: CGFloat
  let direction: CGFloat
  let resize: (CGFloat) -> Void
  @State private var dragStart: CGFloat?

  public init(
    _ title: LocalizedStringKey, axis: Axis, value: CGFloat, direction: CGFloat = 1,
    resize: @escaping (CGFloat) -> Void
  ) {
    self.title = title
    self.axis = axis
    self.value = value
    self.direction = direction
    self.resize = resize
  }

  public var body: some View {
    Divider()
      .overlay {
        Color.clear
          .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
          .contentShape(Rectangle())
          .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
              .onChanged { gesture in
                if dragStart == nil { dragStart = value }
                let offset =
                  axis == .horizontal ? gesture.translation.width : gesture.translation.height
                resize((dragStart ?? value) + offset * direction)
              }
              .onEnded { _ in dragStart = nil }
          )
          .accessibilityLabel(title)
          .accessibilityValue(Text("\(Int(value)) points"))
          .accessibilityAdjustableAction { resize(value + ($0 == .increment ? 20 : -20)) }
      }
  }
}
