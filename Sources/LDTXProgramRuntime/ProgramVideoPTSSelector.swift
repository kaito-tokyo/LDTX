// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia

enum ProgramVideoPTSDecision: Equatable {
    case waitingForMasterPTS
    case advanced(CMTime)
    case stalled(lastPTS: CMTime)
    case rejectedNonMonotonic(lastPTS: CMTime, receivedPTS: CMTime)
    case rejectedMasterSourceChange(expectedKey: String, receivedKey: String)
}

struct ProgramVideoPTSSelector {
    private(set) var masterKey: String?
    private(set) var lastPTS: CMTime?

    mutating func reset() {
        masterKey = nil
        lastPTS = nil
    }

    mutating func select(
        masterKey requestedMasterKey: String?,
        presentationTimesByInputKey: [String: CMTime]
    ) -> ProgramVideoPTSDecision {
        guard let requestedMasterKey else {
            return .waitingForMasterPTS
        }
        if let masterKey, masterKey != requestedMasterKey {
            return .rejectedMasterSourceChange(
                expectedKey: masterKey,
                receivedKey: requestedMasterKey
            )
        }
        masterKey = requestedMasterKey

        guard let receivedPTS = presentationTimesByInputKey[requestedMasterKey],
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
