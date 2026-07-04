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

final class DASHManifestTests: XCTestCase {
    func testGeneratesDynamicMPDWithEmbeddedInitialization() throws {
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let configuration = DASHManifestConfiguration(
            availabilityStartTime: date,
            minimumUpdatePeriodSeconds: 5,
            segmentDurationSeconds: 2,
            initialization: .embedded(data: Data([0x00, 0x01, 0x02]))
        )

        let xml = try DASHManifestGenerator.xml(configuration: configuration)

        XCTAssertTrue(xml.contains(#"type="dynamic""#))
        XCTAssertTrue(xml.contains(#"minimumUpdatePeriod="PT5S""#))
        XCTAssertTrue(xml.contains(#"duration="2000""#))
        XCTAssertTrue(xml.contains(#"media="media$Number%09d$.mp4""#))
        XCTAssertTrue(xml.contains(#"initialization="data:video/mp4;base64,AAEC""#))
        XCTAssertTrue(xml.contains(#"ContentComponent id="1" contentType="video""#))
        XCTAssertTrue(xml.contains(#"ContentComponent id="2" contentType="audio""#))
        XCTAssertTrue(xml.contains(#"codecs="avc1.64002a,mp4a.40.2""#))
        XCTAssertTrue(xml.contains(#"audioSamplingRate="48000""#))
    }

    func testRejectsYouTubeInvalidUpdatePeriod() {
        let configuration = DASHManifestConfiguration(
            minimumUpdatePeriodSeconds: 61,
            initialization: .embedded(data: Data())
        )

        XCTAssertThrowsError(try DASHManifestGenerator.xml(configuration: configuration)) { error in
            XCTAssertEqual(error as? DASHManifestError, .invalidMinimumUpdatePeriod(61))
        }
    }

    func testEmbeddedInitializationUsesStandardBase64() throws {
        let configuration = DASHManifestConfiguration(
            initialization: .embedded(data: Data([0xfb, 0xff, 0xff]))
        )

        let xml = try DASHManifestGenerator.xml(configuration: configuration)

        XCTAssertTrue(xml.contains(#"initialization="data:video/mp4;base64,+///""#))
    }

    func testGeneratesStaticMPDWithFileInitialization() throws {
        let configuration = DASHManifestConfiguration(
            kind: .static,
            mediaPresentationDurationSeconds: 6,
            segmentDurationSeconds: 2,
            initialization: .url("init.mp4")
        )

        let xml = try DASHManifestGenerator.xml(configuration: configuration)

        XCTAssertTrue(xml.contains(#"type="static""#))
        XCTAssertTrue(xml.contains(#"mediaPresentationDuration="PT6S""#))
        XCTAssertTrue(xml.contains(#"initialization="init.mp4""#))
        XCTAssertFalse(xml.contains("availabilityStartTime"))
        XCTAssertFalse(xml.contains("minimumUpdatePeriod"))
    }
}
