// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import LDTXAppletSupport
import LDTXRecording
import OSLog
import Observation

@MainActor
@Observable
@objc(RecordPlayerDocument)
public final class RecordPlayerDocument: NSDocument {
  public nonisolated static let typeName = RecordingPackageInfo.typeIdentifier
  public private(set) var markers: [RecordingMarker] = []
  @ObservationIgnored
  private var savedMarkers: [RecordingMarker] = []
  @ObservationIgnored
  private var markerReadError: (any Error)?
  @ObservationIgnored
  private var hasReadContents = false
  @ObservationIgnored
  private(set) var model: LDTXRecordPlayerModel?
  @ObservationIgnored
  var scenarioFixture: RecordingPreviewScenarioFixture?
  @ObservationIgnored
  var assetLoader: LDTXRecordPlayerAssetLoader = RecordPlayerWindowController.loadAsset
  @ObservationIgnored
  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "RecordPlayerDocument")

  private nonisolated static func accepts(_ typeName: String) -> Bool {
    typeName == Self.typeName || typeName == RecordingPackageInfo.legacyTypeIdentifier
  }

  public override class var autosavesInPlace: Bool { false }
  public override class var preservesVersions: Bool { false }
  public override var autosavingFileType: String? { nil }
  public override var backupFileURL: URL? { nil }

  public override func read(from url: URL, ofType typeName: String) throws {
    try MainActor.assumeIsolated {
      guard Self.accepts(typeName) else { throw CocoaError(.fileReadUnknown) }
      do {
        _ = try RecordingPackage(contentsOf: url)
        let loaded: [RecordingMarker]
        var markerError: (any Error)?
        do {
          loaded = try RecordingMarkerStore(recordingDirectoryURL: url).markers()
        } catch {
          // Revert must preserve current edits if the replacement cannot be read.
          guard !hasReadContents else { throw error }
          logger.error(
            "Reading optional markers failed: \(error.localizedDescription, privacy: .public)")
          loaded = []
          markerError = error
        }
        hasReadContents = true
        markerReadError = markerError
        markers = loaded
        savedMarkers = loaded
      } catch {
        logger.error("Reading recording failed: \(error.localizedDescription, privacy: .public)")
        throw error
      }
    }
  }

  public override func makeWindowControllers() {
    guard windowControllers.isEmpty, fileURL != nil else { return }
    let reference = DocumentReference(self)
    let model = LDTXRecordPlayerModel(
      documentReference: reference, scenarioFixture: scenarioFixture,
      assetLoader: assetLoader)
    self.model = model
    addWindowController(
      RecordPlayerWindowController(
        model: model, documentReference: reference))
  }

  public var canModifyMarkers: Bool {
    guard let url = fileURL else { return false }
    return !FileManager.default.fileExists(atPath: url.appendingPathComponent(".shield.json").path)
  }

  public func createMarker(note: String, at time: CMTime) throws {
    guard let recordingURL = fileURL else { throw CocoaError(.fileWriteUnknown) }
    guard
      !FileManager.default.fileExists(
        atPath: recordingURL.appendingPathComponent(".shield.json").path)
    else {
      throw RecordingMarkerError.recordingInProgress
    }
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecordingMarkerError.emptyNote
    }
    let name = try RecordingMarkerStore.fileName(for: time)
    guard !markers.contains(where: { $0.fileName == name }) else {
      throw RecordingMarkerError.markerAlreadyExists(name)
    }
    markers.append(
      RecordingMarker(
        time: time, timecode: try RecordingMarkerStore.displayTimecode(for: time), note: note,
        fileName: name))
    markers.sort { CMTimeCompare($0.time, $1.time) < 0 }
    updateChangeCount(.changeDone)
  }

  public func deleteMarker(_ marker: RecordingMarker) throws {
    guard let recordingURL = fileURL,
      !FileManager.default.fileExists(
        atPath: recordingURL.appendingPathComponent(".shield.json").path)
    else {
      throw RecordingMarkerError.recordingInProgress
    }
    guard let index = markers.firstIndex(of: marker) else {
      throw RecordingMarkerError.invalidMarkerFile
    }
    markers.remove(at: index)
    updateChangeCount(.changeDone)
  }

  public override func canAsynchronouslyWrite(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
  ) -> Bool { false }

  public override func writeSafely(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
  ) throws {
    try MainActor.assumeIsolated {
      guard saveOperation == .saveOperation, Self.accepts(typeName),
        url.standardizedFileURL == fileURL?.standardizedFileURL
      else { throw RecordingMarkerError.unsupportedOperation }
      if let markerReadError { throw markerReadError }
      let snapshot = markers
      do {
        try RecordingMarkerStore(recordingDirectoryURL: url).save(
          snapshot, replacing: savedMarkers, filePresenter: self)
        savedMarkers = try RecordingMarkerStore(recordingDirectoryURL: url).markers()
      } catch {
        logger.error("Saving markers failed: \(error.localizedDescription, privacy: .public)")
        throw error
      }
    }
  }

  public override func close() {
    model?.stop()
    super.close()
  }

  public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if let action = item.action, prohibitedActions.contains(action) { return false }
    return super.validateUserInterfaceItem(item)
  }

  private var prohibitedActions: [Selector] {
    [
      #selector(saveAs(_:)), #selector(saveTo(_:)), #selector(duplicate(_:)),
      #selector(rename(_:)), #selector(move(_:)), #selector(moveToUbiquityContainer(_:)),
    ]
  }
}
