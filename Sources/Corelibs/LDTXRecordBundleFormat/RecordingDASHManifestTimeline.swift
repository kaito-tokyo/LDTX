// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

public struct RecordingDASHManifestTimeline {
  public static let audioStartScheme = "urn:tokyo.kaito.ldtx:audio-presentation-start-ns"
  private var startsByPath: [String: Int64]
  private var audioStartsByPath: [String: Int64]

  public init(contentsOf manifestURL: URL) throws {
    let parserDelegate = RecordingDASHParserDelegate()
    let parser = XMLParser(data: try Data(contentsOf: manifestURL))
    parser.delegate = parserDelegate
    guard parser.parse(), parser.parserError == nil else {
      throw RecordingDASHManifestError.invalidManifest(
        parser.parserError?.localizedDescription ?? "XML parsing failed"
      )
    }
    startsByPath = parserDelegate.startsByPath
    audioStartsByPath = parserDelegate.audioStartsByPath
  }

  public func presentationStart(for mediaPath: String) -> Int64? {
    startsByPath[mediaPath]
  }

  public func audioPresentationStart(for mediaPath: String) -> Int64? {
    audioStartsByPath[mediaPath]
  }
}

private final class RecordingDASHParserDelegate: NSObject, XMLParserDelegate {
  private var periodStart = 0.0
  private var timescale: Int64 = 1
  private var presentationTimeOffset: Int64 = 0
  private var firstPresentationTime: Int64?
  private var mediaPath: String?

  var startsByPath: [String: Int64] = [:]
  var audioStartsByPath: [String: Int64] = [:]
  private var audioStartNanoseconds: Int64?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    switch elementName {
    case "Representation":
      audioStartNanoseconds = nil
    case "SupplementalProperty"
    where attributeDict["schemeIdUri"] == RecordingDASHManifestTimeline.audioStartScheme:
      guard let value = attributeDict["value"].flatMap(Int64.init) else {
        parser.abortParsing()
        return
      }
      audioStartNanoseconds = value
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
    let (difference, overflow) = firstPresentationTime.subtractingReportingOverflow(
      presentationTimeOffset)
    let ticks: Double
    if !overflow {
      ticks = Double(difference)
    } else if firstPresentationTime > presentationTimeOffset {
      ticks = Double(UInt64(bitPattern: difference))
    } else {
      ticks = -Double(UInt64(bitPattern: presentationTimeOffset &- firstPresentationTime))
    }
    let mediaStart = ticks / Double(timescale)
    let nanoseconds = ((periodStart + mediaStart) * 1_000_000_000).rounded()
    guard nanoseconds.isFinite, nanoseconds >= Double(Int64.min), nanoseconds < Double(Int64.max)
    else {
      return
    }
    startsByPath[mediaPath] = Int64(nanoseconds)
    if let audioStartNanoseconds {
      audioStartsByPath[mediaPath] = audioStartNanoseconds
    }
  }

  private static func seconds(fromISODuration value: String) -> Double? {
    guard value.hasPrefix("PT"), value.hasSuffix("S") else { return nil }
    return Double(value.dropFirst(2).dropLast())
  }
}

public enum RecordingDASHManifestError: Error, Equatable, Sendable {
  case invalidManifest(String)
}
