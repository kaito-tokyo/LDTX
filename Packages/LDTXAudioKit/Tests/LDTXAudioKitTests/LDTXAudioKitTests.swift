// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LDTXAudioKit

final class LDTXAudioKitTests: XCTestCase {
  func testAudioEngineCanBeCreatedWithoutHardware() {
    let engine = AudioEngine(hardwareEnabled: false)
    XCTAssertNotNil(engine)
  }

  func testInputDevicePlaylistWritesByteRangesAndVODEnd() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mediaURL = directory.appendingPathComponent("InputDevices/Microphone.m4a")
    let playlistURL = directory.appendingPathComponent("InputDevices/Microphone.m3u8")
    let playlist = InputDeviceHLSPlaylist(mediaURL: mediaURL, playlistURL: playlistURL)

    try playlist.appendInitialization(.init(offset: 0, length: 128))
    try playlist.append(.init(byteRange: .init(offset: 128, length: 256), duration: 2))
    let event = try String(contentsOf: playlistURL, encoding: .utf8)
    XCTAssertTrue(event.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
    XCTAssertTrue(event.contains("#EXT-X-MAP:URI=\"Microphone.m4a\",BYTERANGE=\"128@0\""))
    XCTAssertTrue(event.contains("#EXT-X-BYTERANGE:256@128"))
    XCTAssertFalse(event.contains("#EXT-X-ENDLIST"))

    try playlist.finish()
    let vod = try String(contentsOf: playlistURL, encoding: .utf8)
    XCTAssertTrue(vod.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    XCTAssertTrue(vod.contains("#EXT-X-ENDLIST"))

    let snapshot = try InputDeviceHLSPlaylist.read(from: playlistURL)
    XCTAssertEqual(snapshot.initialization, .init(offset: 0, length: 128))
    XCTAssertEqual(snapshot.segments, [.init(byteRange: .init(offset: 128, length: 256), duration: 2)])
    XCTAssertTrue(snapshot.isVOD)
  }
}
