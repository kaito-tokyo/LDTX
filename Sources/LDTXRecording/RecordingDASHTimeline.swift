// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

struct RecordingDASHTimeline {
  private var startsByPath: [String: CMTime]

  init(contentsOf manifestURL: URL) throws {
    let parserDelegate = RecordingDASHParserDelegate()
    let parser = XMLParser(data: try Data(contentsOf: manifestURL))
    parser.delegate = parserDelegate
    guard parser.parse() else {
      throw RecordingRemuxerError.invalidManifest(
        parser.parserError?.localizedDescription ?? "XML parsing failed"
      )
    }
    startsByPath = parserDelegate.startsByPath
  }

  func presentationStart(for mediaPath: String) -> CMTime? {
    startsByPath[mediaPath]
  }
}

private final class RecordingDASHParserDelegate: NSObject, XMLParserDelegate {
  private var periodStart = 0.0
  private var timescale: Int64 = 1
  private var presentationTimeOffset: Int64 = 0
  private var firstPresentationTime: Int64?
  private var mediaPath: String?

  var startsByPath: [String: CMTime] = [:]

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    switch elementName {
    case "Period":
      periodStart = Self.seconds(fromISODuration: attributeDict["start"] ?? "PT0S") ?? 0
    case "SegmentList":
      timescale = Int64(attributeDict["timescale"] ?? "1") ?? 1
      presentationTimeOffset = Int64(attributeDict["presentationTimeOffset"] ?? "0") ?? 0
      firstPresentationTime = nil
      mediaPath = nil
    case "Initialization":
      record(media: attributeDict["sourceURL"])
    case "S" where firstPresentationTime == nil:
      firstPresentationTime = Int64(attributeDict["t"] ?? "0") ?? 0
      storeIfComplete()
    case "SegmentURL":
      record(media: attributeDict["media"])
    default:
      break
    }
  }

  private func record(media: String?) {
    guard mediaPath == nil, let media else { return }
    mediaPath = media.removingPercentEncoding ?? media
    storeIfComplete()
  }

  private func storeIfComplete() {
    guard timescale > 0, let mediaPath, let firstPresentationTime else { return }
    let mediaStart = Double(firstPresentationTime - presentationTimeOffset) / Double(timescale)
    startsByPath[mediaPath] = CMTime(seconds: periodStart + mediaStart, preferredTimescale: 1_000_000_000)
  }

  private static func seconds(fromISODuration value: String) -> Double? {
    guard value.hasPrefix("PT"), value.hasSuffix("S") else { return nil }
    return Double(value.dropFirst(2).dropLast())
  }
}
