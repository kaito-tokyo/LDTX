// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RecordingAudioTrack: Equatable, Sendable {
  public var identifier: String
  public var name: String
  public var mediaPath: String
  /// All durable generations for this input device, in recording order.
  /// `mediaPath` remains the primary generation for source compatibility.
  public var mediaPaths: [String]
  public var playlistPath: String?
  public var mediaURL: URL
  public var mediaURLs: [URL]
  public var playlistURL: URL?

  public init(
    identifier: String,
    name: String,
    mediaPath: String,
    mediaPaths: [String]? = nil,
    playlistPath: String? = nil,
    mediaURL: URL,
    mediaURLs: [URL]? = nil,
    playlistURL: URL? = nil
  ) {
    self.identifier = identifier
    self.name = name
    self.mediaPath = mediaPath
    self.mediaPaths = mediaPaths ?? [mediaPath]
    self.playlistPath = playlistPath
    self.mediaURL = mediaURL
    self.mediaURLs = mediaURLs ?? [mediaURL]
    self.playlistURL = playlistURL
  }
}

public struct RecordingPackage: Equatable, Sendable {
  public static let pathExtension = "ldtxrecord"
  /// A zero-byte marker indicating that recording-session shutdown completed.
  ///
  /// Its presence does not guarantee media completeness, playability, or the presence of any
  /// particular track. Use `RecordingPackageVerifier` to evaluate recorded media.
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
  /// Whether recording-session shutdown completed.
  ///
  /// This value does not describe the completeness of the package's media.
  public var isFinalized: Bool
  public var formatVersion: Int
  public var identifier: String
  public var manifestPath: String
  public var mainMediaPath: String
  /// All durable Main Program generations, in recording order.  The first is
  /// always `main.mp4`; later files appear only after isolated writer recovery.
  public var mainMediaPaths: [String]
  public var mainPlaylistPath: String?
  public var masterPlaylistPath: String?
  public var mainMediaURL: URL
  public var mainMediaURLs: [URL]
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
    guard RecordingPackageInfo.supportedFormatVersions.contains(formatVersion) else {
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
    let manifestURL =
      fileManager.fileExists(atPath: candidateManifestURL.path)
      ? candidateManifestURL.standardizedFileURL : nil
    let mainMediaPaths = try Self.mainMediaPaths(
      primaryPath: info.mainMediaFile,
      manifestURL: manifestURL,
      packageURL: directoryURL,
      fileManager: fileManager
    )
    let mainMediaURLs = try mainMediaPaths.map {
      try Self.existingFileURL(relativePath: $0, packageURL: directoryURL, fileManager: fileManager)
    }
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
      let mediaPaths = try Self.mediaGenerationPaths(
        primaryPath: value.mediaFile,
        manifestURL: manifestURL,
        packageURL: directoryURL,
        fileManager: fileManager
      )
      let mediaURLs = try mediaPaths.map {
        try Self.existingFileURL(relativePath: $0, packageURL: directoryURL, fileManager: fileManager)
      }
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
          mediaPaths: mediaPaths,
          playlistPath: value.playlist,
          mediaURL: mediaURL,
          mediaURLs: mediaURLs,
          playlistURL: playlistURL
        ))
    }

    self.directoryURL = directoryURL.standardizedFileURL
    self.isFinalized = isFinalized
    self.formatVersion = formatVersion
    self.identifier = identifier
    self.manifestPath = manifestPath
    self.mainMediaPath = info.mainMediaFile
    self.mainMediaPaths = mainMediaPaths
    self.mainPlaylistPath = info.mainPlaylist
    self.masterPlaylistPath = info.masterPlaylist
    self.mainMediaURL = mainMediaURL
    self.mainMediaURLs = mainMediaURLs
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

  private static func mainMediaPaths(
    primaryPath: String,
    manifestURL: URL?,
    packageURL: URL,
    fileManager: FileManager
  ) throws -> [String] {
    try mediaGenerationPaths(
      primaryPath: primaryPath,
      manifestURL: manifestURL,
      packageURL: packageURL,
      fileManager: fileManager
    )
  }

  private static func mediaGenerationPaths(
    primaryPath: String,
    manifestURL: URL?,
    packageURL: URL,
    fileManager: FileManager
  ) throws -> [String] {
    guard let manifestURL, let timeline = try? RecordingDASHTimeline(contentsOf: manifestURL) else {
      return [primaryPath]
    }
    let fileName = primaryPath.split(separator: "/").last.map(String.init) ?? primaryPath
    let stem = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    let parentPath = primaryPath.lastIndex(of: "/").map {
      String(primaryPath[..<$0])
    } ?? ""
    let parentURL = parentPath.isEmpty
      ? packageURL
      : packageURL.appendingPathComponent(parentPath, isDirectory: true)
    let generations = try fileManager.contentsOfDirectory(
      at: parentURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ).compactMap { candidate -> (Int, String)? in
      let filename = candidate.lastPathComponent
      let relativePath = parentPath.isEmpty ? filename : "\(parentPath)/\(filename)"
      guard candidate.pathExtension == ext, timeline.contains(mediaPath: relativePath) else { return nil }
      if relativePath == primaryPath { return (1, relativePath) }
      guard filename.hasPrefix("\(stem)~"),
        let number = Int(filename.dropFirst(stem.count + 1).dropLast(ext.count + 1)), number > 1
      else { return nil }
      return (number, relativePath)
    }.sorted { $0.0 < $1.0 }.map(\.1)
    if generations.contains(primaryPath) { return generations }
    return [primaryPath] + generations
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
    guard
      let enumerator = fileManager.enumerator(
        at: packageURL,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [],
        errorHandler: { url, _ in
          enumerationFailure.path = relativePath(of: url, in: packageURL)
          return false
        }
      )
    else {
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
