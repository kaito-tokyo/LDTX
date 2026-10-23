// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Publishes a JPEG/JSON pair, rolling back this attempt on failure.
/// This is not a crash-atomic multi-file transaction.
struct VisionResultArchiver {
  enum Operation: String, CaseIterable {
    case directoryCreation, imageGeneration, imageWrite, metadataSerialization, metadataWrite
    case imagePublication, metadataPublication, stagingCleanup
  }

  var fileManager: FileManager = .default
  var currentDate: () -> Date = Date.init
  var writeMetadata: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
  // Deterministic fault injection at the actual operation boundaries.
  var beforeOperation: (Operation) throws -> Void = { _ in }

  private func publish(
    _ source: URL, to destination: URL, owned: inout [URL], cleanupErrors: inout [NSError]
  ) throws {
    let descriptor = destination.withUnsafeFileSystemRepresentation {
      open($0!, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
    }
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    owned.append(destination)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: Data(contentsOf: source))
    } catch {
      let primary = error
      do { try handle.close() } catch { cleanupErrors.append(error as NSError) }
      throw primary
    }
    try handle.close()
  }

  func archive(
    internalID: Int64, image: CIImage, output: String, timelineMilliseconds: UInt64?,
    packageDirectory: URL
  ) throws {
    let directory = packageDirectory.appendingPathComponent("Visions", isDirectory: true)
    let stem = "vision-\(internalID)-\(UInt64(currentDate().timeIntervalSince1970 * 1_000))"
    let imageURL = directory.appendingPathComponent("\(stem).jpg")
    let metadataURL = directory.appendingPathComponent("\(stem).json")
    let staging = directory.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
    var ownsStaging = false
    var published: [URL] = []
    var cleanupErrors: [NSError] = []
    var operation = Operation.directoryCreation
    func begin(_ next: Operation) throws {
      operation = next
      try beforeOperation(next)
    }
    do {
      try begin(.directoryCreation)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      // Never reuse a staging directory belonging to another attempt.
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
      ownsStaging = true
      try begin(.imageGeneration)
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let cgImage = context.createCGImage(image, from: image.extent) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try begin(.imageWrite)
      let stagedImage = staging.appendingPathComponent("image.jpg")
      guard
        let destination = CGImageDestinationCreateWithURL(
          stagedImage as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw CocoaError(.fileWriteUnknown) }
      CGImageDestinationAddImage(destination, cgImage, nil)
      guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
      try begin(.metadataSerialization)
      var metadata: [String: String] = ["visionID": String(internalID), "output": output]
      if let timelineMilliseconds {
        metadata["recordingTimelineMilliseconds"] = String(timelineMilliseconds)
      }
      let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
      try begin(.metadataWrite)
      let stagedMetadata = staging.appendingPathComponent("metadata.json")
      try writeMetadata(data, stagedMetadata)
      // O_EXCL atomically refuses existing destinations. Track ownership as
      // soon as creation succeeds so a partial copy is also rolled back.
      try begin(.imagePublication)
      try publish(stagedImage, to: imageURL, owned: &published, cleanupErrors: &cleanupErrors)
      try begin(.metadataPublication)
      try publish(stagedMetadata, to: metadataURL, owned: &published, cleanupErrors: &cleanupErrors)
      try begin(.stagingCleanup)
      try fileManager.removeItem(at: staging)
      ownsStaging = false
    } catch {
      let primary = error as NSError
      for url in published.reversed() {
        do { try fileManager.removeItem(at: url) } catch { cleanupErrors.append(error as NSError) }
      }
      if ownsStaging {
        do { try fileManager.removeItem(at: staging) } catch {
          cleanupErrors.append(error as NSError)
        }
      }
      // Package URL stays in private diagnostic data, never public logging.
      throw NSError(
        domain: "VisionArchive", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not archive Vision result \(stem) during \(operation.rawValue).",
          NSUnderlyingErrorKey: primary,
          NSURLErrorKey: packageDirectory,
          "VisionArchiveOperation": operation.rawValue,
          "VisionArchiveResult": stem,
          "VisionArchiveCleanupErrors": cleanupErrors,
        ])
    }
  }
}
