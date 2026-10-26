// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import LDTXCorelibs
@testable import LDTXRecordPlayerApplet
import LDTXRecording

@MainActor
func makeRecordingTestPackage() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("ldtxrecord")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  try RecordingPackageInfo.data(
    identifier: "document-test", mainMediaFile: "main.mp4", audioTracks: [], formatVersion: 2
  ).write(to: url.appendingPathComponent(RecordingPackageInfo.fileName))
  try Data().write(to: url.appendingPathComponent("main.mp4"))
  try Data().write(to: url.appendingPathComponent("manifest.mpd"))
  try Data().write(to: url.appendingPathComponent(RecordingPackage.finalizedMarkerFileName))
  return url
}

func readRecordingTestSnapshot(_ url: URL) async throws -> RecordPlayerDocument.Reader.Snapshot {
  let progress = ProgressManager(totalCount: 1)
  return try await RecordPlayerDocument.Reader().read(
    from: url, progress: progress.subprogress(assigningCount: 1))
}

@MainActor
func openRecordingTestDocument(_ url: URL) async throws -> RecordPlayerDocument {
  let document = RecordPlayerDocument(fileURL: url)
  try await document.apply(snapshot: readRecordingTestSnapshot(url), previous: nil)
  return document
}

@MainActor
func saveRecordingTestDocument(_ document: RecordPlayerDocument, to url: URL) async throws {
  let progress = ProgressManager(totalCount: 1)
  try await RecordPlayerDocument.Writer().write(
    snapshot: document.snapshot(contentType: RecordPlayerDocument.readableContentTypes[0]),
    to: url, previous: nil, progress: progress.subprogress(assigningCount: 1))
}
