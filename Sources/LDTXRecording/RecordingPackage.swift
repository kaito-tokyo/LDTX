// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RecordingAudioTrack: Equatable, Sendable {
  public var identifier: String
  public var name: String
  public var mediaPath: String
  public var playlistPath: String?
  public var mediaURL: URL
  public var playlistURL: URL?

  public init(
    identifier: String,
    name: String,
    mediaPath: String,
    playlistPath: String? = nil,
    mediaURL: URL,
    playlistURL: URL? = nil
  ) {
    self.identifier = identifier
    self.name = name
    self.mediaPath = mediaPath
    self.playlistPath = playlistPath
    self.mediaURL = mediaURL
    self.playlistURL = playlistURL
  }
}

public struct RecordingPackage: Equatable, Sendable {
  public static let pathExtension = "ldtxrecord"
  public static let finalizedMarkerFileName = ".finalized"
  public static let manifestFileName = RecordingPackageInfo.manifestFileName
  public static let readmeFileName = "README.md"

  public static let remuxReadme = """
    # LDTX recording package

    This directory is an LDTX recording package. Keep its files together and do
    not modify the media files, `manifest.mpd`, or `Info.plist` before remuxing.

    Use a compatible external media tool to remux the package when needed.
    """

  public var directoryURL: URL
  public var isFinalized: Bool
  public var formatVersion: Int
  public var identifier: String
  public var manifestPath: String
  public var mainMediaPath: String
  public var mainPlaylistPath: String?
  public var masterPlaylistPath: String?
  public var mainMediaURL: URL
  public var manifestURL: URL?
  public var mainPlaylistURL: URL?
  public var masterPlaylistURL: URL?
  public var audioTracks: [RecordingAudioTrack]

  public init(contentsOf directoryURL: URL, fileManager: FileManager = .default) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw RecordingPackageError.packageIsNotDirectory(directoryURL)
    }
    try Self.rejectSymbolicLinks(in: directoryURL, fileManager: fileManager)

    let isFinalized = fileManager.fileExists(
      atPath: directoryURL.appendingPathComponent(Self.finalizedMarkerFileName).path
    )
    let infoURL = directoryURL.appendingPathComponent(RecordingPackageInfo.fileName)
    let data = try Data(contentsOf: infoURL)
    let info: RecordingPackageInfoValue
    do {
      info = try PropertyListDecoder().decode(RecordingPackageInfoValue.self, from: data)
    } catch {
      throw RecordingPackageError.invalidInfoPropertyList
    }

    let formatVersion = info.formatVersion
    guard formatVersion == RecordingPackageInfo.currentFormatVersion else {
      throw RecordingPackageError.unsupportedFormatVersion(formatVersion)
    }

    guard !info.identifier.isEmpty else {
      throw RecordingPackageError.invalidValue(RecordingPackageInfo.identifierKey)
    }
    let identifier = info.identifier
    let mainMediaURL = try Self.existingFileURL(
      relativePath: info.mainMediaFile,
      packageURL: directoryURL,
      fileManager: fileManager
    )
    let manifestPath = Self.manifestFileName
    let candidateManifestURL = directoryURL.appendingPathComponent(manifestPath)
    let manifestURL = fileManager.fileExists(atPath: candidateManifestURL.path)
      ? candidateManifestURL.standardizedFileURL : nil
    let mainPlaylistURL = try Self.optionalFileURL(
      relativePath: info.mainPlaylist,
      packageURL: directoryURL,
      fileManager: fileManager
    )
    let masterPlaylistURL = try Self.optionalFileURL(
      relativePath: info.masterPlaylist,
      packageURL: directoryURL,
      fileManager: fileManager
    )

    var audioTracks: [RecordingAudioTrack] = []
    var identifiers = Set<String>()
    for value in info.audioTracks {
      let trackIdentifier = value.identifier
      guard !trackIdentifier.isEmpty else {
        throw RecordingPackageError.invalidValue("Identifier")
      }
      guard identifiers.insert(trackIdentifier).inserted else {
        throw RecordingPackageError.duplicateAudioTrackIdentifier(trackIdentifier)
      }
      let mediaURL = try Self.existingFileURL(
        relativePath: value.mediaFile,
        packageURL: directoryURL,
        fileManager: fileManager
      )
      let playlistURL = try Self.optionalFileURL(
        relativePath: value.playlist,
        packageURL: directoryURL,
        fileManager: fileManager
      )
      audioTracks.append(
        RecordingAudioTrack(
          identifier: trackIdentifier,
          name: value.name,
          mediaPath: value.mediaFile,
          playlistPath: value.playlist,
          mediaURL: mediaURL,
          playlistURL: playlistURL
        ))
    }

    self.directoryURL = directoryURL.standardizedFileURL
    self.isFinalized = isFinalized
    self.formatVersion = formatVersion
    self.identifier = identifier
    self.manifestPath = manifestPath
    self.mainMediaPath = info.mainMediaFile
    self.mainPlaylistPath = info.mainPlaylist
    self.masterPlaylistPath = info.masterPlaylist
    self.mainMediaURL = mainMediaURL
    self.manifestURL = manifestURL
    self.mainPlaylistURL = mainPlaylistURL
    self.masterPlaylistURL = masterPlaylistURL
    self.audioTracks = audioTracks
  }

  public static func defaultRemuxOutputURL(for packageURL: URL) -> URL {
    packageURL.deletingPathExtension().appendingPathExtension("mp4")
  }

  public func requireFinalized() throws {
    guard isFinalized else {
      throw RecordingPackageError.packageIsNotFinalized(directoryURL)
    }
  }

  private static func optionalFileURL(
    relativePath: String?,
    packageURL: URL,
    fileManager: FileManager
  ) throws -> URL? {
    guard let relativePath else { return nil }
    return try existingFileURL(
      relativePath: relativePath,
      packageURL: packageURL,
      fileManager: fileManager
    )
  }

  private static func rejectSymbolicLinks(
    in packageURL: URL,
    fileManager: FileManager
  ) throws {
    let packageURL = packageURL.standardizedFileURL
    if try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      throw RecordingPackageError.symbolicLinkNotAllowed(packageURL.lastPathComponent)
    }

    let enumerationFailure = RecordingPackageEnumerationFailure()
    guard let enumerator = fileManager.enumerator(
      at: packageURL,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: [],
      errorHandler: { url, _ in
        enumerationFailure.path = relativePath(of: url, in: packageURL)
        return false
      }
    ) else {
      throw RecordingPackageError.cannotEnumeratePackage(packageURL)
    }
    for case let entryURL as URL in enumerator {
      let values: URLResourceValues
      do {
        values = try entryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      } catch {
        throw RecordingPackageError.cannotInspectPackageEntry(
          relativePath(of: entryURL, in: packageURL)
        )
      }
      guard values.isSymbolicLink != true else {
        throw RecordingPackageError.symbolicLinkNotAllowed(
          relativePath(of: entryURL, in: packageURL)
        )
      }
    }
    if let path = enumerationFailure.path {
      throw RecordingPackageError.cannotInspectPackageEntry(path)
    }
  }

  private static func relativePath(of entryURL: URL, in packageURL: URL) -> String {
    for baseURL in [packageURL, packageURL.resolvingSymlinksInPath()] {
      let packagePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
      if entryURL.path.hasPrefix(packagePrefix) {
        return String(entryURL.path.dropFirst(packagePrefix.count))
      }
    }
    return entryURL.lastPathComponent
  }

  private static func existingFileURL(
    relativePath: String,
    packageURL: URL,
    fileManager: FileManager
  ) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
      throw RecordingPackageError.invalidRelativePath(relativePath)
    }
    let packageURL = packageURL.standardizedFileURL
    let fileURL = packageURL.appendingPathComponent(relativePath).standardizedFileURL
    let packagePrefix = packageURL.path.hasSuffix("/") ? packageURL.path : packageURL.path + "/"
    guard fileURL.path.hasPrefix(packagePrefix) else {
      throw RecordingPackageError.invalidRelativePath(relativePath)
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw RecordingPackageError.missingMediaFile(relativePath)
    }
    return fileURL
  }
}

private final class RecordingPackageEnumerationFailure: @unchecked Sendable {
  var path: String?
}

private struct RecordingPackageInfoValue: Decodable {
  struct AudioTrack: Decodable {
    var identifier: String
    var name: String
    var mediaFile: String
    var playlist: String?

    enum CodingKeys: String, CodingKey {
      case identifier = "Identifier"
      case name = "Name"
      case mediaFile = "MediaFile"
      case playlist = "Playlist"
    }
  }

  var formatVersion: Int
  var identifier: String
  var mainMediaFile: String
  var mainPlaylist: String?
  var masterPlaylist: String?
  var audioTracks: [AudioTrack]

  enum CodingKeys: String, CodingKey {
    case formatVersion = "LDTXRecordingFormatVersion"
    case identifier = "LDTXRecordingIdentifier"
    case mainMediaFile = "LDTXRecordingMainMediaFile"
    case mainPlaylist = "LDTXRecordingMainPlaylist"
    case masterPlaylist = "LDTXRecordingMasterPlaylist"
    case audioTracks = "LDTXRecordingAudioTracks"
  }
}

public enum RecordingPackageError: Error, LocalizedError, Equatable, Sendable {
  case packageIsNotDirectory(URL)
  case packageIsNotFinalized(URL)
  case invalidInfoPropertyList
  case invalidValue(String)
  case unsupportedFormatVersion(Int)
  case invalidRelativePath(String)
  case missingMediaFile(String)
  case duplicateAudioTrackIdentifier(String)
  case symbolicLinkNotAllowed(String)
  case cannotEnumeratePackage(URL)
  case cannotInspectPackageEntry(String)

  public var errorDescription: String? {
    switch self {
    case .packageIsNotDirectory(let url):
      "Recording package is not a directory: \(url.path)"
    case .packageIsNotFinalized(let url):
      "Recording package is not finalized: \(url.path)"
    case .invalidInfoPropertyList:
      "Recording Info.plist is not a property-list dictionary."
    case .invalidValue(let key):
      "Recording Info.plist has a missing or invalid \(key) value."
    case .unsupportedFormatVersion(let version):
      "Recording format version \(version) is not supported."
    case .invalidRelativePath(let path):
      "Recording contains an unsafe media path: \(path)"
    case .missingMediaFile(let path):
      "Recording media file is missing: \(path)"
    case .duplicateAudioTrackIdentifier(let identifier):
      "Recording contains duplicate audio track identifier: \(identifier)"
    case .symbolicLinkNotAllowed(let path):
      "Recording package contains a symbolic link: \(path)"
    case .cannotEnumeratePackage(let url):
      "Recording package could not be enumerated: \(url.path)"
    case .cannotInspectPackageEntry(let path):
      "Recording package entry could not be inspected: \(path)"
    }
  }
}
