// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit

final class ContentActionButton: NSButton {
  var invoke: () -> Void = {}
  init(_ title: String, checkbox: Bool = false, invoke: @escaping () -> Void = {}) {
    super.init(frame: .zero)
    self.title = title
    self.invoke = invoke
    if checkbox { setButtonType(.switch) } else { bezelStyle = .rounded }
    target = self
    action = #selector(invokeAction)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func invokeAction() { invoke() }
}

@MainActor
func contentStack(_ views: [NSView], vertical: Bool = true) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = vertical ? .vertical : .horizontal
  stack.alignment = vertical ? .leading : .centerY
  stack.spacing = 8
  return stack
}

@MainActor
func pinContent(_ child: NSView, in parent: NSView, inset: CGFloat = 12) {
  child.translatesAutoresizingMaskIntoConstraints = false
  parent.addSubview(child)
  NSLayoutConstraint.activate([
    child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
    child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
    child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
    child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
  ])
}

private final class ContentScrollDocument: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
func contentScroll(_ stack: NSStackView) -> NSScrollView {
  let scroll = NSScrollView()
  scroll.hasVerticalScroller = true
  let document = ContentScrollDocument()
  scroll.documentView = document
  pinContent(stack, in: document)
  document.translatesAutoresizingMaskIntoConstraints = false
  document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
  return scroll
}
