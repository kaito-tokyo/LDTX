// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import LDTXRecordBundleFormat
import LDTXRecording
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class RecordPlayerDocument: Document {
  public nonisolated static let typeName = RecordingPackageInfo.typeIdentifier
  public nonisolated static let readableContentTypes: [UTType] = {
    let primary = UTType(exportedAs: RecordingPackageInfo.typeIdentifier, conformingTo: .package)
    let legacy = UTType(
      importedAs: RecordingPackageInfo.legacyTypeIdentifier, conformingTo: .package)
    return primary == legacy ? [primary] : [primary, legacy]
  }()

  public private(set) var markers: [RecordingMarker] = []
  private var markerDeletions: [String: UUID] = [:]
  @ObservationIgnored private let configuration: URLDocumentConfiguration?
  private var initialURL: URL?
  @ObservationIgnored private var markerReadError: (any Error)?
  @ObservationIgnored private var hasReadContents = false
  @ObservationIgnored private var playbackModel: LDTXRecordPlayerModel?
  @ObservationIgnored var scenarioFixture: RecordingPreviewScenarioFixture?
  @ObservationIgnored var assetLoader: LDTXRecordPlayerAssetLoader = LDTXRecordPlayerModel.loadAsset

  public var fileURL: URL? { configuration?.fileURL ?? initialURL }
  public var canModifyMarkers: Bool { fileURL != nil }

  init(configuration: URLDocumentConfiguration) {
    self.configuration = configuration
    initialURL = configuration.fileURL
  }

  init(fileURL: URL) {
    configuration = nil
    initialURL = fileURL
  }

  var model: LDTXRecordPlayerModel {
    if let playbackModel { return playbackModel }
    let model = LDTXRecordPlayerModel(
      document: self, scenarioFixture: scenarioFixture, assetLoader: assetLoader)
    playbackModel = model
    return model
  }

  isolated deinit { playbackModel?.stop() }

  public nonisolated func reader(configuration: sending ReadConfiguration) -> sending Reader {
    Reader()
  }
  public nonisolated func writer(configuration: sending WriteConfiguration) -> sending Writer {
    Writer()
  }

  public func apply(snapshot: sending Reader.Snapshot, previous: sending Reader.Snapshot?)
    async throws
  {
    if hasReadContents, let error = snapshot.markerReadError { throw error }
    if let previous {
      let old = Dictionary(uniqueKeysWithValues: previous.markers.map { ($0.fileName, $0) })
      let current = Dictionary(uniqueKeysWithValues: markers.map { ($0.fileName, $0) })
      var incoming = Dictionary(uniqueKeysWithValues: snapshot.markers.map { ($0.fileName, $0) })
      for name in Set(old.keys).union(current.keys) where old[name] != current[name] {
        incoming[name] = current[name]
      }
      markers = incoming.values.sorted { CMTimeCompare($0.time, $1.time) < 0 }
    } else {
      markers = snapshot.markers
      markerDeletions.removeAll()
    }
    for marker in markers { markerDeletions.removeValue(forKey: marker.fileName) }
    initialURL = snapshot.url
    markerReadError = snapshot.markerReadError
    hasReadContents = true
  }

  public func snapshot(contentType: UTType) async throws -> sending Writer.Snapshot {
    guard Self.readableContentTypes.contains(contentType) else {
      throw RecordingMarkerError.unsupportedOperation
    }
    if let markerReadError { throw markerReadError }
    guard let fileURL else { throw RecordingMarkerError.unsupportedOperation }
    return Writer.Snapshot(
      url: fileURL, markers: markers, markerDeletions: markerDeletions)
  }

  public func createMarker(note: String, at time: CMTime, undoManager: UndoManager? = nil) throws {
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecordingMarkerError.emptyNote
    }
    let name = try RecordingMarkerStore.fileName(for: time)
    let index = try markers.firstIndex { try RecordingMarkerStore.fileName(for: $0.time) == name }
    let marker = RecordingMarker(
      time: time, timecode: try RecordingMarkerStore.displayTimecode(for: time), note: note,
      fileName: index.map { markers[$0].fileName } ?? name)
    var updated = markers
    if let index { updated[index] = marker } else { updated.append(marker) }
    updated.sort { CMTimeCompare($0.time, $1.time) < 0 }
    replaceMarkers(updated, undoManager: undoManager)
  }

  private func replaceMarkers(
    _ updated: [RecordingMarker], undoManager: UndoManager?,
    actionName: String = String(localized: "Edit Marker")
  ) {
    let previous = markers
    undoManager?.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        target.replaceMarkers(previous, undoManager: undoManager, actionName: actionName)
      }
    }
    undoManager?.setActionName(actionName)
    let remaining = Set(updated.map(\.fileName))
    for name in Set(previous.map(\.fileName)).subtracting(remaining) {
      markerDeletions[name] = UUID()
    }
    for name in remaining { markerDeletions.removeValue(forKey: name) }
    markers = updated
  }

  public func deleteMarker(_ marker: RecordingMarker, undoManager: UndoManager? = nil) throws {
    guard canModifyMarkers else { throw RecordingMarkerError.unsupportedOperation }
    guard let index = markers.firstIndex(of: marker) else {
      throw RecordingMarkerError.invalidMarkerFile
    }
    var updated = markers
    updated.remove(at: index)
    replaceMarkers(
      updated, undoManager: undoManager, actionName: String(localized: "Delete Marker"))
  }

  public struct Reader: DocumentReader {
    public struct Snapshot: Sendable {
      let url: URL
      let markers: [RecordingMarker]
      let markerReadError: (any Error)?
    }

    @concurrent public func read(
      from source: sending URL, progress: consuming Subprogress
    ) async throws -> sending Snapshot {
      let progress = progress.start(totalCount: 2)
      _ = try RecordingPackage(contentsOf: source)
      progress.complete(count: 1)
      let markers: [RecordingMarker]
      var markerError: (any Error)?
      do {
        markers = try RecordingMarkerStore(recordingDirectoryURL: source).markers()
      } catch {
        markers = []
        markerError = error
      }
      progress.complete(count: 1)
      return Snapshot(url: source, markers: markers, markerReadError: markerError)
    }
  }

  public struct Writer: DocumentWriter {
    public struct Snapshot: Sendable {
      let url: URL
      let markers: [RecordingMarker]
      let markerDeletions: [String: UUID]
    }

    @concurrent public func write(
      snapshot: sending Snapshot, to destination: sending URL,
      previous: sending Snapshot?, progress: consuming Subprogress
    ) async throws {
      // DocumentGroup supplies a coordinated staging copy during safe saving.
      _ = try RecordingPackage(contentsOf: destination)
      let progress = progress.start(totalCount: 1)
      _ = try RecordingMarkerStore(recordingDirectoryURL: destination)
        .saveWithinCoordinatedAccess(
          snapshot.markers,
          deleting: Set(
            snapshot.markerDeletions.compactMap { name, token in
              // SwiftUI supplies the previous successfully written snapshot. A failed
              // write does not acknowledge deletions; Undo/Redo generates a new token.
              previous?.markerDeletions[name] == token ? nil : name
            }))
      progress.complete(count: 1)
    }
  }
}
