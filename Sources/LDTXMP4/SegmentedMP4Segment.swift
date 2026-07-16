// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SegmentedMP4SegmentKind: Equatable, Sendable {
    case initialization
    case media(number: Int)
}

public struct SegmentedMP4Segment: Equatable, Sendable {
    public var kind: SegmentedMP4SegmentKind
    public var data: Data
    public var durationSeconds: Double?
    public var earliestPresentationTimeSeconds: Double?

    public init(
        kind: SegmentedMP4SegmentKind,
        data: Data,
        durationSeconds: Double? = nil,
        earliestPresentationTimeSeconds: Double? = nil
    ) {
        self.kind = kind
        self.data = data
        self.durationSeconds = durationSeconds
        self.earliestPresentationTimeSeconds = earliestPresentationTimeSeconds
    }
}
