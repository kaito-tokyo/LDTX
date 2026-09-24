// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import LDTXProgramRuntime
import UniformTypeIdentifiers

final class ScreenCaptureService: @unchecked Sendable {
  private struct PixelBufferDescriptor: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
  }

  private let fileManager: FileManager
  private let currentDate: () -> Date
  private let softwareIdentifier: String
  private let colorSpace: CGColorSpace
  private let context: CIContext
  private var pixelBufferPools: [PixelBufferDescriptor: CVPixelBufferPool] = [:]

  init(fileManager: FileManager = .default, currentDate: @escaping () -> Date = Date.init) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    self.fileManager = fileManager
    self.currentDate = currentDate
    softwareIdentifier = Self.makeSoftwareIdentifier()
    self.colorSpace = colorSpace
    context = CIContext(options: [
      .workingColorSpace: colorSpace,
      .outputColorSpace: colorSpace,
    ])
  }

  func captureSet(
    sources: [ScreenCaptureSource],
    capturedAt: Date,
    recordingPackageDirectory: URL
  ) throws -> ScreenCaptureSetResult {
    guard !sources.isEmpty else {
      throw ScreenCaptureError.frameUnavailable
    }
    let screenshotsDirectory = try prepareScreenshotsDirectory(
      in: recordingPackageDirectory)

    let timestamp = SessionRecordService.makeTimestamp(date: capturedAt)
    var outputURLs: [URL] = []
    do {
      for source in sources {
        let outputURL = uniqueOutputURL(
          in: screenshotsDirectory,
          name: source.name,
          timestamp: timestamp)
        try jpegData(
          from: source.pixelBuffer,
          sourceName: source.name,
          capturedAt: capturedAt
        ).write(to: outputURL, options: .atomic)
        outputURLs.append(outputURL)
      }
    } catch {
      for outputURL in outputURLs {
        try? fileManager.removeItem(at: outputURL)
      }
      throw error
    }
    return ScreenCaptureSetResult(
      directory: screenshotsDirectory,
      capturedAt: capturedAt,
      outputURLs: outputURLs)
  }

  func prepareScreenshotsDirectory(in recordingPackageDirectory: URL) throws -> URL {
    let directory = recordingPackageDirectory.appendingPathComponent(
      "Screenshots", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @MainActor
  func captureDate() -> Date {
    currentDate()
  }

  @MainActor
  func snapshot(pixelBuffer: CVPixelBuffer, name: String) throws -> ScreenCaptureSource {
    let descriptor = PixelBufferDescriptor(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer),
      pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer))
    let pool = try pixelBufferPool(for: descriptor)
    var copy: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &copy)
    guard status == kCVReturnSuccess, let copy else {
      throw ScreenCaptureError.pixelBufferCopyFailed(status)
    }

    let sourceLockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard sourceLockStatus == kCVReturnSuccess else {
      throw ScreenCaptureError.pixelBufferCopyFailed(sourceLockStatus)
    }
    let destinationLockStatus = CVPixelBufferLockBaseAddress(copy, [])
    guard destinationLockStatus == kCVReturnSuccess else {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
      throw ScreenCaptureError.pixelBufferCopyFailed(destinationLockStatus)
    }
    defer {
      CVPixelBufferUnlockBaseAddress(copy, [])
      CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
    if planeCount == 0 {
      Self.copyRows(
        from: CVPixelBufferGetBaseAddress(pixelBuffer),
        sourceBytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        to: CVPixelBufferGetBaseAddress(copy),
        destinationBytesPerRow: CVPixelBufferGetBytesPerRow(copy),
        height: CVPixelBufferGetHeight(pixelBuffer))
    } else {
      for planeIndex in 0..<planeCount {
        Self.copyRows(
          from: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex),
          sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex),
          to: CVPixelBufferGetBaseAddressOfPlane(copy, planeIndex),
          destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(copy, planeIndex),
          height: CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex))
      }
    }
    CVBufferPropagateAttachments(pixelBuffer, copy)
    return ScreenCaptureSource(name: name, pixelBuffer: copy)
  }

  private func jpegData(
    from pixelBuffer: CVPixelBuffer,
    sourceName: String,
    capturedAt: Date
  ) throws -> Data {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let extent = CGRect(
      x: 0,
      y: 0,
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer))
    guard
      let cgImage = context.createCGImage(
        image,
        from: extent,
        format: .RGBX8,
        colorSpace: colorSpace)
    else {
      throw ScreenCaptureError.imageCreationFailed
    }
    let data = NSMutableData()
    let dateMetadata = makeDateMetadata(capturedAt)
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        [
          kCGImageDestinationDateTime: dateMetadata.iso8601,
          kCGImageDestinationOrientation: 1,
        ] as CFDictionary)
    else {
      throw ScreenCaptureError.imageDestinationCreationFailed
    }
    CGImageDestinationAddImage(
      destination,
      cgImage,
      [
        kCGImageDestinationLossyCompressionQuality: 0.92,
        kCGImageDestinationBackgroundColor: CGColor(
          red: 0, green: 0, blue: 0, alpha: 1),
        kCGImagePropertyOrientation: 1,
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifDateTimeOriginal: dateMetadata.exifDateTime,
          kCGImagePropertyExifOffsetTimeOriginal: dateMetadata.offset,
          kCGImagePropertyExifSubsecTimeOriginal: dateMetadata.subseconds,
        ],
        kCGImagePropertyTIFFDictionary: [
          kCGImagePropertyTIFFDateTime: dateMetadata.exifDateTime,
          kCGImagePropertyTIFFImageDescription: sourceName,
          kCGImagePropertyTIFFOrientation: 1,
          kCGImagePropertyTIFFSoftware: softwareIdentifier,
        ],
      ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ScreenCaptureError.imageEncodingFailed
    }
    return data as Data
  }

  private func uniqueOutputURL(in directory: URL, name: String, timestamp: String) -> URL {
    let encodedName = percentEncodedComponentName(name)
    let stem = "\(encodedName.isEmpty ? "Frame" : encodedName)-\(timestamp)"
    var candidate = directory.appendingPathComponent(stem).appendingPathExtension("jpg")
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(
        "jpg")
      suffix += 1
    }
    return candidate
  }

  private func percentEncodedComponentName(_ name: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  private func makeDateMetadata(_ date: Date) -> (
    iso8601: String,
    exifDateTime: String,
    offset: String,
    subseconds: String
  ) {
    let iso8601Formatter = ISO8601DateFormatter()
    iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    iso8601Formatter.timeZone = .autoupdatingCurrent

    let exifFormatter = DateFormatter()
    exifFormatter.locale = Locale(identifier: "en_US_POSIX")
    exifFormatter.calendar = Calendar(identifier: .gregorian)
    exifFormatter.timeZone = .autoupdatingCurrent
    exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

    let subsecondFormatter = DateFormatter()
    subsecondFormatter.locale = Locale(identifier: "en_US_POSIX")
    subsecondFormatter.calendar = Calendar(identifier: .gregorian)
    subsecondFormatter.timeZone = .autoupdatingCurrent
    subsecondFormatter.dateFormat = "SSS"

    return (
      iso8601Formatter.string(from: date),
      exifFormatter.string(from: date),
      Self.exifOffset(for: date),
      subsecondFormatter.string(from: date)
    )
  }

  private static func exifOffset(for date: Date) -> String {
    let seconds = TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)
    let sign = seconds < 0 ? "-" : "+"
    let absoluteSeconds = abs(seconds)
    return String(
      format: "%@%02d:%02d",
      sign,
      absoluteSeconds / 3_600,
      absoluteSeconds % 3_600 / 60)
  }

  private static func makeSoftwareIdentifier() -> String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return switch (version, build) {
    case (.some(let version), .some(let build)):
      "LDTX \(version) (\(build))"
    case (.some(let version), .none):
      "LDTX \(version)"
    case (.none, .some(let build)):
      "LDTX (\(build))"
    case (.none, .none):
      "LDTX"
    }
  }

  @MainActor
  private func pixelBufferPool(
    for descriptor: PixelBufferDescriptor
  ) throws -> CVPixelBufferPool {
    if let pool = pixelBufferPools[descriptor] {
      return pool
    }
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      [kCVPixelBufferPoolMinimumBufferCountKey as String: 1] as CFDictionary,
      [
        kCVPixelBufferWidthKey as String: descriptor.width,
        kCVPixelBufferHeightKey as String: descriptor.height,
        kCVPixelBufferPixelFormatTypeKey as String: descriptor.pixelFormat,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ] as CFDictionary,
      &pool)
    guard status == kCVReturnSuccess, let pool else {
      throw ScreenCaptureError.pixelBufferCopyFailed(status)
    }
    pixelBufferPools[descriptor] = pool
    return pool
  }

  private static func copyRows(
    from source: UnsafeMutableRawPointer?,
    sourceBytesPerRow: Int,
    to destination: UnsafeMutableRawPointer?,
    destinationBytesPerRow: Int,
    height: Int
  ) {
    guard let source, let destination else { return }
    let byteCount = min(sourceBytesPerRow, destinationBytesPerRow)
    for row in 0..<height {
      memcpy(
        destination.advanced(by: row * destinationBytesPerRow),
        source.advanced(by: row * sourceBytesPerRow),
        byteCount)
    }
  }
}

struct ScreenCaptureSource: @unchecked Sendable {
  let name: String
  let pixelBuffer: CVPixelBuffer
}

struct ScreenCaptureSetResult: Sendable {
  let directory: URL
  let capturedAt: Date
  let outputURLs: [URL]
}

enum ScreenCaptureError: LocalizedError {
  case frameUnavailable
  case pixelBufferCopyFailed(OSStatus)
  case imageCreationFailed
  case imageDestinationCreationFailed
  case imageEncodingFailed

  var errorDescription: String? {
    switch self {
    case .frameUnavailable:
      "The Program has not produced a frame yet."
    case .pixelBufferCopyFailed(let status):
      "The current frame could not be copied (Core Video error \(status))."
    case .imageCreationFailed:
      "The current Program frame could not be converted to an image."
    case .imageDestinationCreationFailed:
      "A JPEG image destination could not be created."
    case .imageEncodingFailed:
      "The current Program frame could not be encoded as JPEG."
    }
  }
}
