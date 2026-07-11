// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

public enum CaptureWarmupGateDecision: Sendable, Equatable {
    case skipped
    case opened
    case accepted
    case audioFormatChanged(
        deviceID: String,
        previous: AudioStreamBasicDescription,
        current: AudioStreamBasicDescription
    )
}

public final class CaptureWarmupGate: @unchecked Sendable {
    private struct AudioState {
        var candidate: AudioStreamBasicDescription?
        var consecutiveMatchCount = 0
        var stable: AudioStreamBasicDescription?
    }

    private let lock = NSLock()
    private let requiredAudioDeviceIDs: Set<String>
    private let requiredConsecutiveSampleCount: Int
    private var audioStatesByDeviceID: [String: AudioState]
    private var isOpen: Bool

    public init(
        requiredAudioDeviceIDs: Set<String>,
        requiredConsecutiveSampleCount: Int = 3
    ) {
        self.requiredAudioDeviceIDs = requiredAudioDeviceIDs
        self.requiredConsecutiveSampleCount = max(requiredConsecutiveSampleCount, 1)
        audioStatesByDeviceID = Dictionary(
            uniqueKeysWithValues: requiredAudioDeviceIDs.map { ($0, AudioState()) }
        )
        isOpen = requiredAudioDeviceIDs.isEmpty
    }

    public func observe(
        audioFormat: AudioStreamBasicDescription?,
        deviceID: String,
        kind: CameraCaptureSampleKind
    ) -> CaptureWarmupGateDecision {
        lock.withLock {
            if isOpen {
                guard kind == .audio,
                      requiredAudioDeviceIDs.contains(deviceID),
                      let audioFormat,
                      let stable = audioStatesByDeviceID[deviceID]?.stable,
                      stable != audioFormat else {
                    return .accepted
                }
                return .audioFormatChanged(
                    deviceID: deviceID,
                    previous: stable,
                    current: audioFormat
                )
            }

            guard kind == .audio,
                  requiredAudioDeviceIDs.contains(deviceID),
                  let audioFormat,
                  var state = audioStatesByDeviceID[deviceID] else {
                return .skipped
            }

            if state.candidate == audioFormat {
                state.consecutiveMatchCount += 1
            } else {
                state.candidate = audioFormat
                state.consecutiveMatchCount = 1
            }
            if state.consecutiveMatchCount >= requiredConsecutiveSampleCount {
                state.stable = audioFormat
            }
            audioStatesByDeviceID[deviceID] = state

            guard requiredAudioDeviceIDs.allSatisfy({ audioStatesByDeviceID[$0]?.stable != nil }) else {
                return .skipped
            }
            isOpen = true
            return .opened
        }
    }

    public var stableAudioFormatsByDeviceID: [String: AudioStreamBasicDescription] {
        lock.withLock {
            audioStatesByDeviceID.compactMapValues(\.stable)
        }
    }

    public var isWarmedUp: Bool {
        lock.withLock { isOpen }
    }
}
