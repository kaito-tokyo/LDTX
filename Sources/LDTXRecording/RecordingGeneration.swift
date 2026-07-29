// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RecordingTrackID: Hashable, Sendable, Codable {
  case outputVideo
  case outputAudio
  case inputDeviceAudio(String)
}

public enum RecordingGenerationState: String, Sendable, Codable {
  case writing
  case finished
  case interrupted
}

public struct RecordingCommittedFragment: Equatable, Sendable, Codable {
  public var byteOffset: Int64
  public var byteLength: Int64
  public var presentationTimeSeconds: Double
  public var durationSeconds: Double

  public init(
    byteOffset: Int64,
    byteLength: Int64,
    presentationTimeSeconds: Double,
    durationSeconds: Double
  ) {
    self.byteOffset = byteOffset
    self.byteLength = byteLength
    self.presentationTimeSeconds = presentationTimeSeconds
    self.durationSeconds = durationSeconds
  }
}

public struct RecordingGeneration: Equatable, Sendable, Codable, Identifiable {
  public var trackID: RecordingTrackID
  public var number: Int
  public var mediaFile: String
  public var startPresentationTimeSeconds: Double
  public var fragments: [RecordingCommittedFragment]
  public var state: RecordingGenerationState

  public var id: String { "\(trackID.stableIdentifier):\(number)" }

  public init(
    trackID: RecordingTrackID,
    number: Int,
    mediaFile: String,
    startPresentationTimeSeconds: Double,
    fragments: [RecordingCommittedFragment] = [],
    state: RecordingGenerationState = .writing
  ) {
    precondition(number > 0)
    self.trackID = trackID
    self.number = number
    self.mediaFile = mediaFile
    self.startPresentationTimeSeconds = startPresentationTimeSeconds
    self.fragments = fragments
    self.state = state
  }
}

public struct RecordingCutRequest: Equatable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var requestedAtUptimeSeconds: Double

  public init(id: UUID = UUID(), requestedAtUptimeSeconds: Double) {
    self.id = id
    self.requestedAtUptimeSeconds = requestedAtUptimeSeconds
  }
}

public extension RecordingTrackID {
  var stableIdentifier: String {
    switch self {
    case .outputVideo:
      "output-video"
    case .outputAudio:
      "output-audio"
    case .inputDeviceAudio(let id):
      "input-device-audio:\(id)"
    }
  }

  func mediaFileName(generation: Int, inputDeviceFileNameStem: String? = nil) -> String {
    precondition(generation > 0)
    let stem: String
    switch self {
    case .outputVideo:
      stem = "output-video"
    case .outputAudio:
      stem = "output-audio"
    case .inputDeviceAudio:
      stem = inputDeviceFileNameStem ?? "InputDevices/Audio"
    }
    return generation == 1 ? "\(stem).mp4" : "\(stem)~\(generation).mp4"
  }
}
