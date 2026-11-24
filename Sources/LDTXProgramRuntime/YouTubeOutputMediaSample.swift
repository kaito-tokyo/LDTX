// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct YouTubeOutputMediaTime: Equatable, Sendable {
  var value: Int64
  var timescale: Int32
}

struct YouTubeOutputH264Format: Equatable, Sendable {
  var parameterSets: [Data]
  var nalUnitHeaderLength: Int32
  var width: Int32
  var height: Int32
}

struct YouTubeOutputH264AccessUnit: Equatable, Sendable {
  var presentationTime: YouTubeOutputMediaTime
  var decodeTime: YouTubeOutputMediaTime?
  var duration: YouTubeOutputMediaTime
  var isKeyFrame: Bool
  var avccData: Data
}
