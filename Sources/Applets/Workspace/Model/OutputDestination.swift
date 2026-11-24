// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum YouTubeIngestMode: UInt32, Codable, CaseIterable, Equatable, Sendable {
  case dash = 0
  case dualRTMPS = 1
}

public struct OutputDestination: Codable, Equatable, Sendable {
  public var recordsLandscape: Bool
  public var recordsPortrait: Bool
  public var streamsToYouTube: Bool
  public var youtubeIngestMode: YouTubeIngestMode
  public var overridesOutputFolder: Bool
  public var outputFolderPath: String?
  public var recordingCustomFields: [String: String]

  public init(
    recordsLocally: Bool = true,
    recordsLandscape: Bool? = nil,
    recordsPortrait: Bool = false,
    streamsToYouTube: Bool = false,
    youtubeIngestMode: YouTubeIngestMode = .dash,
    overridesOutputFolder: Bool = false,
    outputFolderPath: String? = nil,
    recordingCustomFields: [String: String] = [:]
  ) {
    self.recordsLandscape = recordsLandscape ?? recordsLocally
    self.recordsPortrait = recordsPortrait
    self.streamsToYouTube = streamsToYouTube
    self.youtubeIngestMode = youtubeIngestMode
    self.overridesOutputFolder = overridesOutputFolder
    self.outputFolderPath = outputFolderPath
    self.recordingCustomFields = recordingCustomFields
  }

  public var recordsLocally: Bool {
    get { recordsLandscape || recordsPortrait }
    set {
      recordsLandscape = newValue
      if !newValue { recordsPortrait = false }
    }
  }

  /// Returns a structurally normalized value without consulting the current
  /// filesystem. Folder availability is validated immediately before output starts.
  public func normalized(fileManager _: FileManager = .default) -> OutputDestination? {
    guard overridesOutputFolder else {
      return outputFolderPath == nil ? self : nil
    }
    guard let outputFolderPath, !outputFolderPath.isEmpty else { return nil }
    let url = URL(fileURLWithPath: outputFolderPath, isDirectory: true).standardizedFileURL
    var result = self
    result.outputFolderPath = url.path
    return result
  }

  /// Concrete destination written into every newly created Workspace.
  public static let newWorkspaceInitialValue = OutputDestination(
    recordsLocally: true,
    streamsToYouTube: false
  )

  /// Recovery-only value for persisted preferences that predate or omit the
  /// destination message. Its behavior is intentionally not a migration contract.
  public static let missingPersistedValueFallback = OutputDestination(
    recordsLocally: true,
    streamsToYouTube: false
  )
}

public struct ApplicationOutputPreferences: Codable, Equatable, Sendable {
  public var defaultOutputFolderPath: String?
  public var screenshotsFolderPath: String?
  /// Security-scoped bookmark for `defaultOutputFolderPath`; see ``SecurityScopedFolder``.
  public var defaultOutputFolderBookmark: Data?
  /// Security-scoped bookmark for `screenshotsFolderPath`; see ``SecurityScopedFolder``.
  public var screenshotsFolderBookmark: Data?

  public init(
    defaultOutputFolderPath: String? = nil,
    screenshotsFolderPath: String? = nil,
    defaultOutputFolderBookmark: Data? = nil,
    screenshotsFolderBookmark: Data? = nil
  ) {
    self.defaultOutputFolderPath = defaultOutputFolderPath
    self.screenshotsFolderPath = screenshotsFolderPath
    self.defaultOutputFolderBookmark = defaultOutputFolderBookmark
    self.screenshotsFolderBookmark = screenshotsFolderBookmark
  }

  /// Selects the default recording folder, or restores the standard Movies folder for nil.
  public mutating func setDefaultOutputFolder(_ url: URL?) {
    defaultOutputFolderPath = url?.standardizedFileURL.path
    defaultOutputFolderBookmark = url.flatMap(SecurityScopedFolder.bookmark(for:))
  }

  /// Selects the screenshots folder, or restores the standard Pictures folder for nil.
  public mutating func setScreenshotsFolder(_ url: URL?) {
    screenshotsFolderPath = url?.standardizedFileURL.path
    screenshotsFolderBookmark = url.flatMap(SecurityScopedFolder.bookmark(for:))
  }

  /// The user-selected default recording folder, or nil to use the standard Movies folder.
  public var defaultOutputDirectory: URL? {
    SecurityScopedFolder.url(path: defaultOutputFolderPath, bookmark: defaultOutputFolderBookmark)
  }

  public var screenshotsDirectory: URL {
    SecurityScopedFolder.url(path: screenshotsFolderPath, bookmark: screenshotsFolderBookmark)
      ?? Self.standardPicturesDirectory
  }

  /// The user's Pictures folder. Under the App Sandbox `URL.picturesDirectory` names the
  /// container's link to it, so the link is resolved to keep Finder and displayed paths real.
  public static var standardPicturesDirectory: URL {
    URL.picturesDirectory.resolvingSymlinksInPath()
  }

  /// The user's Movies folder, resolved the same way as ``standardPicturesDirectory``.
  public static var standardMoviesDirectory: URL {
    URL.moviesDirectory.resolvingSymlinksInPath()
  }
}
