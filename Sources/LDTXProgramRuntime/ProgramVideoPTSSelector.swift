// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

enum ProgramVideoPTSDecision: Equatable {
    case waitingForMasterPTS
    case advanced(CMTime)
    case stalled(lastPTS: CMTime)
    case rejectedNonMonotonic(lastPTS: CMTime, receivedPTS: CMTime)
    case rejectedMasterSourceChange(expectedKey: String, receivedKey: String)
}

struct ProgramVideoPTSSelector {
    private(set) var masterCameraID: String?
    private(set) var masterCaptureSessionID: UUID?
    private(set) var lastPTS: CMTime?

    mutating func reset() {
        masterCameraID = nil
        masterCaptureSessionID = nil
        lastPTS = nil
    }

    mutating func select(
        masterCameraID requestedMasterCameraID: String?,
        masterCaptureSessionID requestedMasterCaptureSessionID: UUID? = nil,
        masterPresentationTime: CMTime?
    ) -> ProgramVideoPTSDecision {
        guard let requestedMasterCameraID else {
            reset()
            return .advanced(CMClockGetTime(CMClockGetHostTimeClock()))
        }
        if let masterCameraID, masterCameraID != requestedMasterCameraID {
            return .rejectedMasterSourceChange(
                expectedKey: masterCameraID,
                receivedKey: requestedMasterCameraID
            )
        }
        if let requestedMasterCaptureSessionID {
            if masterCameraID == requestedMasterCameraID,
               let masterCaptureSessionID,
               masterCaptureSessionID != requestedMasterCaptureSessionID {
                lastPTS = nil
            }
            masterCaptureSessionID = requestedMasterCaptureSessionID
        }
        masterCameraID = requestedMasterCameraID

        guard let receivedPTS = masterPresentationTime,
              receivedPTS.isNumeric else {
            if let lastPTS {
                return .stalled(lastPTS: lastPTS)
            }
            return .waitingForMasterPTS
        }

        guard let lastPTS else {
            self.lastPTS = receivedPTS
            return .advanced(receivedPTS)
        }
        let comparison = CMTimeCompare(receivedPTS, lastPTS)
        if comparison > 0 {
            self.lastPTS = receivedPTS
            return .advanced(receivedPTS)
        }
        if comparison == 0 {
            return .stalled(lastPTS: lastPTS)
        }
        return .rejectedNonMonotonic(lastPTS: lastPTS, receivedPTS: receivedPTS)
    }
}
