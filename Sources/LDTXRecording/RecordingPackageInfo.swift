// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RecordingPackageInfoAudioTrack: Equatable, Sendable {
  public var identifier: String
  public var name: String
  public var mediaFile: String

  public init(identifier: String, name: String, mediaFile: String) {
    self.identifier = identifier
    self.name = name
    self.mediaFile = mediaFile
  }
}

public enum RecordingPackageInfo {
  public static let fileName = "Info.plist"
  public static let currentFormatVersion = 2
  public static let supportedFormatVersions = 1...currentFormatVersion
  public static let typeIdentifier = "tokyo.kaito.ldtx.recording"
  public static let manifestFileName = "manifest.mpd"
  public static let formatVersionKey = "LDTXRecordingFormatVersion"
  public static let identifierKey = "LDTXRecordingIdentifier"
  public static let manifestFileKey = "LDTXRecordingManifestFile"
  public static let mainMediaFileKey = "LDTXRecordingMainMediaFile"
  public static let audioTracksKey = "LDTXRecordingAudioTracks"

  public static func data(
    identifier: String,
    mainMediaFile: String,
    audioTracks: [RecordingPackageInfoAudioTrack],
    formatVersion: Int = currentFormatVersion
  ) throws -> Data {
    guard supportedFormatVersions.contains(formatVersion) else {
      throw RecordingPackageInfoError.unsupportedFormatVersion(formatVersion)
    }
    let audioTrackValues = audioTracks.map { track in
      let value = [
        "Identifier": track.identifier,
        "Name": track.name,
        "MediaFile": track.mediaFile,
      ]
      return value
    }
    let values: [String: Any] = [
      "CFBundleIdentifier": typeIdentifier,
      "CFBundleInfoDictionaryVersion": "6.0",
      "CFBundleName": identifier,
      "CFBundlePackageType": "BNDL",
      audioTracksKey: audioTrackValues,
      formatVersionKey: formatVersion,
      identifierKey: identifier,
      manifestFileKey: manifestFileName,
      mainMediaFileKey: mainMediaFile,
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
  }
}

public enum RecordingPackageInfoError: Error, Equatable, Sendable {
  case unsupportedFormatVersion(Int)
}
