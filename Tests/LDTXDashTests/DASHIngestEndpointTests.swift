// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import Testing

struct DASHIngestEndpointTests {
    @Test func appendsObjectNameToFileQueryParameter() throws {
        let endpoint = DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&copy=0&file=")!)

        let url = endpoint.url(for: .manifest)

        #expect(url.absoluteString == "https://upload.youtube.com/dash_upload?cid=abc&copy=0&file=source.mpd")
    }

    @Test func appendsObjectNameToPathEndpoint() throws {
        let endpoint = DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash/stream/")!)

        let url = endpoint.url(for: try DASHObjectName.mediaSegment(number: 42))

        #expect(url.absoluteString == "https://upload.youtube.com/dash/stream/media000000042.mp4")
    }

    @Test func buildsMPDReferenceFromFileQueryEndpoint() {
        let endpoint = DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&copy=0&file=")!)

        let reference = endpoint.mpdReference(for: "media$Number%09d$.mp4")

        #expect(reference == "/dash_upload?cid=abc&copy=0&file=media$Number%09d$.mp4")
    }

    @Test func rejectsUnsafeObjectNames() {
        #expect(throws: DASHObjectNameError.self) { try DASHObjectName(validating: "../source.mpd") }
        #expect(throws: DASHObjectNameError.self) { try DASHObjectName(validating: "source/mpd") }
        #expect(throws: DASHObjectNameError.self) { try DASHObjectName.mediaSegment(number: -1) }
    }
}
