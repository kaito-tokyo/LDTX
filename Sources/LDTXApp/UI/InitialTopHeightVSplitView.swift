// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct InitialTopHeightVSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    var initialTopHeight: CGFloat
    var minTopHeight: CGFloat
    var minBottomHeight: CGFloat
    var top: Top
    var bottom: Bottom

    init(
        initialTopHeight: CGFloat = 128,
        minTopHeight: CGFloat = 72,
        minBottomHeight: CGFloat = 320,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.initialTopHeight = initialTopHeight
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
        self.top = top()
        self.bottom = bottom()
    }

    func makeNSView(context: Context) -> InitialTopHeightSplitView<Top, Bottom> {
        InitialTopHeightSplitView(
            initialTopHeight: initialTopHeight,
            minTopHeight: minTopHeight,
            minBottomHeight: minBottomHeight,
            top: top,
            bottom: bottom
        )
    }

    func updateNSView(
        _ nsView: InitialTopHeightSplitView<Top, Bottom>,
        context: Context
    ) {
        nsView.update(
            initialTopHeight: initialTopHeight,
            minTopHeight: minTopHeight,
            minBottomHeight: minBottomHeight,
            top: top,
            bottom: bottom
        )
    }
}

final class InitialTopHeightSplitView<Top: View, Bottom: View>: NSView, NSSplitViewDelegate {
    private let splitView = NSSplitView()
    private let topHostingView: NSHostingView<Top>
    private let bottomHostingView: NSHostingView<Bottom>
    private var initialTopHeight: CGFloat
    private var minTopHeight: CGFloat
    private var minBottomHeight: CGFloat
    private var didApplyInitialTopHeight = false

    init(
        initialTopHeight: CGFloat,
        minTopHeight: CGFloat,
        minBottomHeight: CGFloat,
        top: Top,
        bottom: Bottom
    ) {
        self.initialTopHeight = initialTopHeight
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
        self.topHostingView = NSHostingView(rootView: top)
        self.bottomHostingView = NSHostingView(rootView: bottom)
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        initialTopHeight: CGFloat,
        minTopHeight: CGFloat,
        minBottomHeight: CGFloat,
        top: Top,
        bottom: Bottom
    ) {
        self.initialTopHeight = initialTopHeight
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
        topHostingView.rootView = top
        bottomHostingView.rootView = bottom
        needsLayout = true
    }

    override func layout() {
        super.layout()
        applyInitialTopHeightIfNeeded()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minTopHeight
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(minTopHeight, splitView.bounds.height - splitView.dividerThickness - minBottomHeight)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view == bottomHostingView
    }

    private func setup() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self

        topHostingView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        bottomHostingView.setContentHuggingPriority(.defaultLow, for: .vertical)

        addSubview(splitView)
        splitView.addArrangedSubview(topHostingView)
        splitView.addArrangedSubview(bottomHostingView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyInitialTopHeightIfNeeded() {
        guard !didApplyInitialTopHeight,
              splitView.bounds.height > 0,
              splitView.arrangedSubviews.count == 2 else {
            return
        }

        let maximumTopHeight = max(
            minTopHeight,
            splitView.bounds.height - splitView.dividerThickness - minBottomHeight
        )
        let topHeight = min(max(initialTopHeight, minTopHeight), maximumTopHeight)

        splitView.setPosition(topHeight, ofDividerAt: 0)
        didApplyInitialTopHeight = true
    }
}
