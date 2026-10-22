// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
@testable import LDTXWorkspaceAppletService
import Synchronization
import Testing

@Suite
struct ScreenCaptureServiceIntegrationTestSuite {
  @Test func savesIdenticalImagesGloballyAndInsideRecording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let global = root.appendingPathComponent("Pictures")
    let recording = root.appendingPathComponent("Recording.ldtxrecord/Screenshots")
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixelBuffer = try #require(buffer)
    let service = ScreenCaptureService()
    let result = try service.captureSet(
      sources: [.init(name: "Landscape", pixelBuffer: pixelBuffer, programCanvas: .landscape)],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [global, recording])
    #expect(result.outputURLs.count == 2)
    #expect(result.screenshots.allSatisfy { $0.programCanvas == .landscape })
    let first = try #require(result.outputURLs.first)
    let second = try #require(result.outputURLs.last)
    #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    let standalone = try service.captureSet(
      sources: [.init(name: "Landscape", pixelBuffer: pixelBuffer)],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [global])
    #expect(standalone.outputURLs.count == 1)
    #expect(standalone.screenshots.first?.programCanvas == nil)
    #expect(!result.outputURLs.contains(try #require(standalone.outputURLs.first)))
    #expect(throws: (any Error).self) {
      try service.captureSet(sources: [], capturedAt: Date(), outputDirectories: [global])
    }
  }
}

@MainActor
@Suite struct ScreenCaptureBackgroundIntegrationTestSuite {
  @Test func snapshotSurvivesSourceMutationAndWritesInOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = DispatchQueue(label: "test.screenshot-background")
    let fileManager = CaptureThreadFileManager()
    let service = ScreenCaptureService(fileManager: fileManager, captureQueue: queue)
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
    let original = try #require(buffer)
    CVPixelBufferLockBaseAddress(original, [])
    memset(
      CVPixelBufferGetBaseAddress(original), 0,
      CVPixelBufferGetBytesPerRow(original) * CVPixelBufferGetHeight(original))
    CVPixelBufferUnlockBaseAddress(original, [])
    let snapshot = try service.snapshot(
      pixelBuffer: original, name: "Landscape", programCanvas: .landscape)
    CVPixelBufferLockBaseAddress(original, [])
    memset(
      CVPixelBufferGetBaseAddress(original), 255,
      CVPixelBufferGetBytesPerRow(original) * CVPixelBufferGetHeight(original))
    CVPixelBufferUnlockBaseAddress(original, [])
    CVPixelBufferLockBaseAddress(snapshot.pixelBuffer, .readOnly)
    #expect(CVPixelBufferGetBaseAddress(snapshot.pixelBuffer)?.load(as: UInt8.self) == 0)
    CVPixelBufferUnlockBaseAddress(snapshot.pixelBuffer, .readOnly)
    let release = DispatchSemaphore(value: 0)
    queue.async { _ = release.wait(timeout: .now() + 10) }
    defer { release.signal() }
    var started = false
    var completed = false
    let first = Task {
      started = true
      let result = try await service.enqueueCapture(
        sources: [snapshot],
        capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [root])
      completed = true
      return result
    }
    while !started { await Task.yield() }
    #expect(!completed)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    release.signal()
    let one = try await first.value
    #expect(fileManager.executedOffMain.withLock { $0 } == true)
    let two = try await service.enqueueCapture(
      sources: [snapshot],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [root])
    #expect(one.screenshots.first?.programCanvas == .landscape)
    #expect(two.outputURLs.first?.lastPathComponent.contains("-2.jpg") == true)
    #expect(
      try Data(contentsOf: #require(one.outputURLs.first))
        == Data(contentsOf: #require(two.outputURLs.first)))
  }

  @Test func workspacesSharingDestinationKeepDistinctCaptures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstService = ScreenCaptureService()
    let secondService = ScreenCaptureService()
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        == kCVReturnSuccess)
    let source = try firstService.snapshot(pixelBuffer: #require(buffer), name: "Landscape")
    async let first = firstService.enqueueCapture(
      sources: [source],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [root])
    async let second = secondService.enqueueCapture(
      sources: [source],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [root])
    let results = try await [first, second]
    #expect(Set(results.flatMap(\.outputURLs)).count == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
  }

  @Test func measuresSyntheticFrameCaptureCosts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ScreenCaptureService()
    for (width, height) in [(1920, 1080), (3840, 2160)] {
      var buffer: CVPixelBuffer?
      #expect(
        CVPixelBufferCreate(
          kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
      let pixelBuffer = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
      let count = CVPixelBufferGetBytesPerRow(pixelBuffer) * height
      // Fixed deterministic texture, without live capture devices or app interaction.
      for index in 0..<count {
        bytes[index] = UInt8(truncatingIfNeeded: index &* 31 ^ (index >> 8))
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      for iteration in 0..<3 {
        let start = ContinuousClock.now
        _ = try service.captureSet(
          sources: [.init(name: "baseline", pixelBuffer: pixelBuffer)],
          capturedAt: Date(), outputDirectories: [root])
        let baseline = start.duration(to: .now)
        let snapshotStart = ContinuousClock.now
        let snapshot = try service.snapshot(pixelBuffer: pixelBuffer, name: "background")
        let snapshotCost = snapshotStart.duration(to: .now)
        let saveStart = ContinuousClock.now
        _ = try await service.enqueueCapture(
          sources: [snapshot], capturedAt: Date(), outputDirectories: [root])
        print(
          "SCREENSHOT_BENCH size=\(width)x\(height) iteration=\(iteration) syncMain=\(baseline) snapshotMain=\(snapshotCost) backgroundElapsed=\(saveStart.duration(to: .now))"
        )
      }
    }
  }

  @Test(arguments: [false, true])
  func destinationFailureRollsBackGlobalAndPackage(packageFails: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let global = root.appendingPathComponent("global")
    let package = root.appendingPathComponent("package")
    let failed = packageFails ? package : global
    let service = ScreenCaptureService(
      fileManager: ReplacedDestinationFileManager(destination: failed))
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        == kCVReturnSuccess)
    let source = try service.snapshot(pixelBuffer: #require(buffer), name: "Landscape")
    do {
      _ = try await service.enqueueCapture(
        sources: [source], capturedAt: Date(),
        outputDirectories: [global, package])
      Issue.record("Either destination failure must fail the whole capture")
    } catch {
      let unaffected = packageFails ? global : package
      #expect(try FileManager.default.contentsOfDirectory(atPath: unaffected.path).isEmpty)
      #expect(try Data(contentsOf: failed).isEmpty)
    }
  }

  @Test func backgroundWriteFailureRollsBackEntireSet() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ScreenCaptureService()
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        == kCVReturnSuccess)
    let source = try service.snapshot(pixelBuffer: #require(buffer), name: "Landscape")
    // NAME_MAX is exceeded only at write time, after the first image was written.
    do {
      _ = try await service.enqueueCapture(
        sources: [
          source,
          .init(name: String(repeating: "x", count: 300), pixelBuffer: source.pixelBuffer),
        ],
        capturedAt: Date(), outputDirectories: [root])
      Issue.record("Expected an invalid filename failure")
    } catch {
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
  }
}

private final class CaptureThreadFileManager: FileManager, @unchecked Sendable {
  let executedOffMain = Mutex<Bool?>(nil)

  override func createDirectory(
    at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    executedOffMain.withLock { $0 = !Thread.isMainThread }
    try super.createDirectory(
      at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}

/// Simulates a destination being replaced between directory preparation and writing.
private final class ReplacedDestinationFileManager: FileManager, @unchecked Sendable {
  let destination: URL
  init(destination: URL) {
    self.destination = destination
    super.init()
  }

  override func createDirectory(
    at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    if url == destination {
      try super.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url)
    } else {
      try super.createDirectory(
        at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
  }
}
