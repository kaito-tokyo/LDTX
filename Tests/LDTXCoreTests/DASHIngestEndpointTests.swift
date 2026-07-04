// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
 import LDTXCapture
 import LDTXDash
 import LDTXMedia
 import LDTXOAuth
 import LDTXSupport
 import LDTXYouTube

final class DASHIngestEndpointTests: XCTestCase {
    func testAppendsObjectNameToFileQueryParameter() throws {
        let endpoint = DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&copy=0&file=")!)

        let url = endpoint.url(for: .manifest)

        XCTAssertEqual(url.absoluteString, "https://upload.youtube.com/dash_upload?cid=abc&copy=0&file=source.mpd")
    }

    func testAppendsObjectNameToPathEndpoint() throws {
        let endpoint = DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash/stream/")!)

        let url = endpoint.url(for: try DASHObjectName.mediaSegment(number: 42))

        XCTAssertEqual(url.absoluteString, "https://upload.youtube.com/dash/stream/media000000042.mp4")
    }

    func testBuildsMPDReferenceFromFileQueryEndpoint() {
        let endpoint = DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&copy=0&file=")!)

        let reference = endpoint.mpdReference(for: "media$Number%09d$.mp4")

        XCTAssertEqual(reference, "/dash_upload?cid=abc&copy=0&file=media$Number%09d$.mp4")
    }

    func testRejectsUnsafeObjectNames() {
        XCTAssertThrowsError(try DASHObjectName(validating: "../source.mpd"))
        XCTAssertThrowsError(try DASHObjectName(validating: "source/mpd"))
        XCTAssertThrowsError(try DASHObjectName.mediaSegment(number: -1))
    }
}
