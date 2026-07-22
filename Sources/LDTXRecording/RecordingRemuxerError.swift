// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RecordingRemuxerError: Error, LocalizedError, Equatable, Sendable {
  case outputAlreadyExists(URL)
  case missingTrack(URL, String)
  case missingFormatDescription(URL, String)
  case cannotCreateCompositionTrack(String)
  case cannotCreateExportSession
  case cannotCreateReaderOutput(String)
  case cannotCreateWriterInput(String)
  case cannotStartWriter
  case cannotStartReader
  case readerFailed
  case cannotRetimeSample(String)
  case writerAppendFailed
  case writerFailed
  case writerCancelled
  case writerFinishFailed
  case invalidManifest(String)

  public var errorDescription: String? {
    switch self {
    case .outputAlreadyExists(let url):
      "Output already exists: \(url.path)"
    case .missingTrack(let url, let mediaType):
      "No \(mediaType) track was found in \(url.path)."
    case .missingFormatDescription(let url, let mediaType):
      "No \(mediaType) format description was found in \(url.path)."
    case .cannotCreateCompositionTrack(let mediaType):
      "A \(mediaType) composition track could not be created."
    case .cannotCreateExportSession:
      "A passthrough MP4 export session could not be created."
    case .cannotCreateReaderOutput(let mediaType):
      "A passthrough reader output could not be created for \(mediaType)."
    case .cannotCreateWriterInput(let mediaType):
      "A passthrough writer input could not be created for \(mediaType)."
    case .cannotStartWriter:
      "The passthrough MP4 writer could not start."
    case .cannotStartReader:
      "A passthrough media reader could not start."
    case .readerFailed:
      "A passthrough media reader failed."
    case .cannotRetimeSample(let mediaType):
      "A \(mediaType) sample could not be placed on the recording timeline."
    case .writerAppendFailed:
      "The passthrough MP4 writer rejected a sample."
    case .writerFailed:
      "The passthrough MP4 writer failed."
    case .writerCancelled:
      "The passthrough MP4 writer was cancelled."
    case .writerFinishFailed:
      "The passthrough MP4 writer could not finish."
    case .invalidManifest(let reason):
      "The MPEG-DASH manifest is invalid: \(reason)"
    }
  }
}
