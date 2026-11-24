// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Observation

/// Edits the application-wide YouTube RTMPS stream key configurations shown in Settings.
///
/// Every change is written to the Keychain immediately through ``WorkspaceAppletData``,
/// whose observable collection also feeds the Workspace inspectors' stream key pickers.
/// Each write starts from the collection currently in the Keychain, so a failed load
/// never lets a save replace configurations the app could not read.
@MainActor
@Observable
public final class YouTubeStreamKeySettingsModel {
  private let appletData: WorkspaceAppletData
  public private(set) var loadErrorMessage: String?

  public init(appletData: WorkspaceAppletData = .shared) {
    self.appletData = appletData
  }

  public var configurations: [YouTubeRTMPSStreamKeyConfiguration] {
    appletData.youtubeStreamKeyConfigurations
  }

  public func reload() {
    do {
      _ = try appletData.loadYouTubeStreamKeyConfigurations()
      loadErrorMessage = nil
    } catch {
      loadErrorMessage = error.localizedDescription
    }
  }

  /// Saves `draft` as a new configuration, or replaces the configuration with the same ID.
  /// - Returns: The configuration as saved, with surrounding whitespace removed.
  @discardableResult
  public func save(_ draft: YouTubeRTMPSStreamKeyConfiguration) throws
    -> YouTubeRTMPSStreamKeyConfiguration
  {
    var stored = try loadForWriting()
    let previous = stored.first { $0.id == draft.id }
    var configuration = Self.normalized(draft)
    if let previous,
      previous.streamURL != configuration.streamURL
        || previous.backupServerURL != configuration.backupServerURL
        || previous.streamKey != configuration.streamKey
    {
      configuration.sourceLiveStreamID = nil
    }
    try write(configuration, into: &stored)
    return configuration
  }

  /// Saves a configuration retrieved from a YouTube LiveStream.
  ///
  /// Importing a LiveStream that an existing configuration came from refreshes that
  /// configuration's connection fields and keeps its ID and name, so Workspace assignments
  /// stay valid. A new import gets a name that no other configuration uses.
  @discardableResult
  public func importConfiguration(_ imported: YouTubeRTMPSStreamKeyConfiguration) throws
    -> YouTubeRTMPSStreamKeyConfiguration
  {
    var stored = try loadForWriting()
    var configuration = Self.normalized(imported)
    if let source = configuration.sourceLiveStreamID,
      let existing = stored.first(where: { $0.sourceLiveStreamID == source })
    {
      configuration.id = existing.id
      configuration.name = existing.name
    } else {
      configuration.id = UUID().uuidString
      configuration.name = Self.uniqueName(configuration.name, among: stored)
    }
    try write(configuration, into: &stored)
    return configuration
  }

  private func write(
    _ configuration: YouTubeRTMPSStreamKeyConfiguration,
    into stored: inout [YouTubeRTMPSStreamKeyConfiguration]
  ) throws {
    if let message = Self.validationMessage(for: configuration, among: stored) {
      throw YouTubeStreamKeySettingsError(message: message)
    }
    if let index = stored.firstIndex(where: { $0.id == configuration.id }) {
      stored[index] = configuration
    } else {
      stored.append(configuration)
    }
    try appletData.saveYouTubeStreamKeyConfigurations(stored)
  }

  static func uniqueName(
    _ name: String, among configurations: [YouTubeRTMPSStreamKeyConfiguration]
  ) -> String {
    let names = Set(configurations.map { normalized($0).name })
    guard names.contains(name) else { return name }
    var suffix = 2
    while names.contains("\(name) (\(suffix))") { suffix += 1 }
    return "\(name) (\(suffix))"
  }

  public func delete(id: YouTubeRTMPSStreamKeyConfiguration.ID) throws {
    var stored = try loadForWriting()
    stored.removeAll { $0.id == id }
    try appletData.saveYouTubeStreamKeyConfigurations(stored)
  }

  /// Describes the first problem that prevents `draft` from being saved, or returns `nil`.
  /// Fields are compared after removing surrounding whitespace, as ``save(_:)`` stores them.
  public static func validationMessage(
    for draft: YouTubeRTMPSStreamKeyConfiguration,
    among configurations: [YouTubeRTMPSStreamKeyConfiguration]
  ) -> String? {
    let configuration = normalized(draft)
    let others = configurations.filter { $0.id != configuration.id }
    if configuration.name.isEmpty { return String(localized: "Enter a name.") }
    if configuration.streamURL.isEmpty { return String(localized: "Enter a stream URL.") }
    if configuration.streamKey.isEmpty { return String(localized: "Enter a stream key.") }
    var primaryOnly = configuration
    primaryOnly.backupServerURL = ""
    if (try? primaryOnly.destination()) == nil {
      return String(
        localized: "The stream URL must be an rtmps:// URL on port 443 with one path component.")
    }
    if (try? configuration.destination()) == nil {
      return String(
        localized:
          "The backup server URL must be an rtmps:// URL on port 443 with one path component.")
    }
    if others.contains(where: { normalized($0).name == configuration.name }) {
      return String(localized: "Another stream key already uses this name.")
    }
    if others.contains(where: { normalized($0).streamKey == configuration.streamKey }) {
      return String(localized: "Another configuration already uses this stream key.")
    }
    return nil
  }

  static func normalized(
    _ configuration: YouTubeRTMPSStreamKeyConfiguration
  ) -> YouTubeRTMPSStreamKeyConfiguration {
    var normalized = configuration
    normalized.name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.streamURL = configuration.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.backupServerURL = configuration.backupServerURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    normalized.streamKey = configuration.streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized
  }

  private func loadForWriting() throws -> [YouTubeRTMPSStreamKeyConfiguration] {
    do {
      let stored = try appletData.loadYouTubeStreamKeyConfigurations()
      loadErrorMessage = nil
      return stored
    } catch {
      loadErrorMessage = error.localizedDescription
      throw error
    }
  }
}

public struct YouTubeStreamKeySettingsError: LocalizedError, Equatable {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}
