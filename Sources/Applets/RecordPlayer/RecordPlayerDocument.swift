// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import LDTXAppletSupport
import LDTXRecording
import OSLog

@MainActor
@objc(RecordPlayerDocument)
public final class RecordPlayerDocument: NSDocument {
  public nonisolated static let typeName = RecordingPackageInfo.typeIdentifier
  public private(set) var markers: [RecordingMarker] = []
  private var savedMarkers: [RecordingMarker] = []
  private var markerReadError: (any Error)?
  private var hasReadContents = false
  private(set) var model: LDTXRecordPlayerModel?
  var scenarioFixture: RecordingPreviewScenarioFixture?
  var assetLoader: LDTXRecordPlayerAssetLoader = RecordPlayerWindowController.loadAsset
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
        model?.markers = loaded
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
    model.markers = markers
    model.createDocumentMarker = { [weak self] note, time in
      guard let self else { throw CocoaError(.fileWriteUnknown) }
      try self.createMarker(note: note, at: time)
    }
    model.deleteDocumentMarker = { [weak self] marker in
      guard let self else { throw CocoaError(.fileWriteUnknown) }
      try self.deleteMarker(marker)
    }
    self.model = model
    addWindowController(
      RecordPlayerWindowController(
        model: model, documentReference: reference))
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
    model?.markers = markers
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
    model?.markers = markers
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
  public override func saveAs(_ sender: Any?) {
    presentError(RecordingMarkerError.unsupportedOperation)
  }
  public override func saveTo(_ sender: Any?) {
    presentError(RecordingMarkerError.unsupportedOperation)
  }
  public override func duplicate(_ sender: Any?) {
    presentError(RecordingMarkerError.unsupportedOperation)
  }
  public override func duplicate() throws -> NSDocument {
    throw RecordingMarkerError.unsupportedOperation
  }
  public override func rename(_ sender: Any?) {
    presentError(RecordingMarkerError.unsupportedOperation)
  }
  public override func move(_ sender: Any?) {
    presentError(RecordingMarkerError.unsupportedOperation)
  }
  public override func moveToUbiquityContainer(_ sender: Any?) {
    presentError(RecordingMarkerError.unsupportedOperation)
  }
  public override func move(completionHandler: ((Bool) -> Void)? = nil) {
    completionHandler?(false)
  }
  public override func move(to url: URL, completionHandler: ((Error?) -> Void)? = nil) {
    completionHandler?(RecordingMarkerError.unsupportedOperation)
  }
}
