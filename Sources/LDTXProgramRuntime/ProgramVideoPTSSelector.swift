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

/// Selects the Program frame PTS from the configured PTS master.
///
/// Some capture devices stamp frames on a coarser clock than their frame
/// cadence (for example, re-anchoring every 40 ms), so consecutive source PTS
/// alternate between short and long intervals although every frame arrives.
/// When a frame duration is supplied, advanced PTS are snapped to a constant
/// frame-rate grid anchored at the first master PTS of the epoch. Rounding to
/// the nearest grid slot keeps each output within half a frame of its source
/// PTS, so the timeline cannot drift from the master clock.
struct ProgramVideoPTSSelector {
  private(set) var masterCameraID: String?
  private(set) var masterCaptureSessionID: UUID?
  /// The latest accepted master source PTS, before grid snapping.
  private(set) var lastPTS: CMTime?
  private var grid: ProgramVideoPTSGrid?

  mutating func reset() {
    masterCameraID = nil
    masterCaptureSessionID = nil
    lastPTS = nil
    grid = nil
  }

  mutating func select(
    masterCameraID requestedMasterCameraID: String?,
    masterCaptureSessionID requestedMasterCaptureSessionID: UUID? = nil,
    masterPresentationTime: CMTime?,
    frameDuration: CMTime? = nil
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
        masterCaptureSessionID != requestedMasterCaptureSessionID
      {
        lastPTS = nil
        grid = nil
      }
      masterCaptureSessionID = requestedMasterCaptureSessionID
    }
    masterCameraID = requestedMasterCameraID

    guard let receivedPTS = masterPresentationTime,
      receivedPTS.isNumeric
    else {
      if let lastPTS {
        return .stalled(lastPTS: lastPTS)
      }
      return .waitingForMasterPTS
    }

    guard let lastPTS else {
      self.lastPTS = receivedPTS
      return advance(to: receivedPTS, frameDuration: frameDuration)
    }
    let comparison = CMTimeCompare(receivedPTS, lastPTS)
    if comparison > 0 {
      self.lastPTS = receivedPTS
      return advance(to: receivedPTS, frameDuration: frameDuration)
    }
    if comparison == 0 {
      return .stalled(lastPTS: lastPTS)
    }
    return .rejectedNonMonotonic(lastPTS: lastPTS, receivedPTS: receivedPTS)
  }

  private mutating func advance(
    to sourcePTS: CMTime,
    frameDuration: CMTime?
  ) -> ProgramVideoPTSDecision {
    guard let frameDuration, frameDuration.isNumeric,
      CMTimeCompare(frameDuration, .zero) > 0
    else {
      grid = nil
      return .advanced(sourcePTS)
    }
    if grid == nil || grid?.frameDuration != frameDuration {
      grid = ProgramVideoPTSGrid(origin: sourcePTS, frameDuration: frameDuration)
      return .advanced(sourcePTS)
    }
    guard let snappedPTS = grid?.snap(sourcePTS) else {
      // The source outpaces the output frame rate; drop this frame rather
      // than letting the snapped timeline run ahead of the master clock.
      return .stalled(lastPTS: sourcePTS)
    }
    return .advanced(snappedPTS)
  }
}

/// A constant frame-rate timeline anchored at one master PTS.
private struct ProgramVideoPTSGrid {
  let origin: CMTime
  let frameDuration: CMTime
  private var lastIndex: Int64 = 0

  init(origin: CMTime, frameDuration: CMTime) {
    self.origin = origin
    self.frameDuration = frameDuration
  }

  /// Returns the grid PTS for a source PTS, or nil when the next free slot
  /// would lie more than one frame ahead of the source.
  mutating func snap(_ sourcePTS: CMTime) -> CMTime? {
    let elapsed = CMTimeSubtract(sourcePTS, origin).seconds
    let duration = frameDuration.seconds
    guard elapsed.isFinite, duration > 0 else { return nil }
    let nearestIndex = Int64((elapsed / duration).rounded())
    let index = max(nearestIndex, lastIndex + 1)
    let snappedPTS = CMTimeAdd(
      origin,
      CMTime(value: index * frameDuration.value, timescale: frameDuration.timescale)
    )
    let lead = CMTimeSubtract(snappedPTS, sourcePTS)
    guard CMTimeCompare(lead, frameDuration) <= 0 else { return nil }
    lastIndex = index
    return snappedPTS
  }
}
