// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

public enum CaptureWarmupGateDecision: Sendable, Equatable {
    case skipped
    case accepted
    case opened
}

public final class CaptureWarmupGate: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: CMTime
    private var firstVideoPresentationTime: CMTime?
    private var isOpen = false

    public init(durationSeconds: Double) {
        duration = CMTime(seconds: max(0, durationSeconds), preferredTimescale: 1_000_000)
        if duration.seconds <= 0 {
            isOpen = true
        }
    }

    public func observe(sampleBuffer: CMSampleBuffer, kind: CameraCaptureSampleKind) -> CaptureWarmupGateDecision {
        lock.withLock {
            guard !isOpen else { return .accepted }
            guard kind == .video else { return .skipped }

            let presentationTime = sampleBuffer.presentationTimeStamp
            guard presentationTime.isNumeric else { return .skipped }

            guard let firstVideoPresentationTime else {
                self.firstVideoPresentationTime = presentationTime
                return .skipped
            }

            let elapsed = CMTimeSubtract(presentationTime, firstVideoPresentationTime)
            guard elapsed.isNumeric, elapsed >= duration else {
                return .skipped
            }

            isOpen = true
            return .opened
        }
    }
}
