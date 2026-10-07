// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecordBundleFormat
import LDTXRecording
import Testing

@Suite struct RecordingPackageVerifierIntegrationTestSuite {
  @Test func verifierRejectsZeroByteMedia() async throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let package = try RecordingPackage(contentsOf: packageURL)

    await #expect(
      throws: RecordingPackageVerificationError.invalidMediaFile("main-stream.mp4")
    ) {
      try await RecordingPackageVerifier().verify(package)
    }
  }

  private func makePackage(
    mainMediaFile: String = "main-stream.mp4",
    formatVersion: Int = 2
  ) throws -> URL {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    for name in [
      "main-stream.mp4", "main-audio.mp4", "side-track.mp4", "manifest.mpd",
    ] {
      FileManager.default.createFile(
        atPath: packageURL.appendingPathComponent(name).path,
        contents: Data()
      )
    }
    let info = try RecordingPackageInfo.data(
      identifier: "recording-test",
      mainMediaFile: mainMediaFile,
      audioTracks: [
        RecordingPackageInfoAudioTrack(
          identifier: "main",
          name: "Main Mix",
          mediaFile: "main-audio.mp4"
        ),
        RecordingPackageInfoAudioTrack(
          identifier: "microphone",
          name: "Microphone",
          mediaFile: "side-track.mp4"
        ),
      ],
      formatVersion: formatVersion
    )
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))
    return packageURL
  }
}
