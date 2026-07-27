// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import OSLog

private let diagnosticsLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "load-diagnostics"
)

public struct DiagnosticsSchemaFailure: Sendable {
  public let databaseURL: URL
  public let description: String
}

public final class DiagnosticsSamplingService: @unchecked Sendable {
  public typealias SchemaFailureHandler = @MainActor @Sendable (DiagnosticsSchemaFailure) -> Void

  private let location: DiagnosticsDatabaseLocation
  private let launchID: UUID
  private let launchUptimeNanoseconds: UInt64
  private let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.load-diagnostics",
    qos: .utility
  )
  private let schemaFailureHandler: SchemaFailureHandler
  private var timer: DispatchSourceTimer?
  private var database: DiagnosticsDatabase?
  private var sampleBuffer = DiagnosticsSampleBuffer(capacity: 6)

  public init(
    location: DiagnosticsDatabaseLocation,
    launchID: UUID = UUID(),
    launchUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
    schemaFailureHandler: @escaping SchemaFailureHandler
  ) {
    self.location = location
    self.launchID = launchID
    self.launchUptimeNanoseconds = launchUptimeNanoseconds
    self.schemaFailureHandler = schemaFailureHandler
  }

  public var currentLaunchID: UUID { launchID }

  public func start() {
    queue.async { [weak self] in self?.startOnQueue() }
  }

  public func stopBestEffort() {
    queue.async { [weak self] in
      guard let self else { return }
      timer?.cancel()
      timer = nil
      flush()
      database?.close()
      database = nil
    }
  }

  private func startOnQueue() {
    do {
      database = try DiagnosticsDatabase(location: location, createIfMissing: true)
    } catch let error as DiagnosticsDatabaseError {
      diagnosticsLogger.error(
        "Diagnostics database open failed: \(error.localizedDescription, privacy: .public)")
      if case .schemaMismatch(let url, let detail) = error {
        Task { @MainActor in
          schemaFailureHandler(DiagnosticsSchemaFailure(databaseURL: url, description: detail))
        }
      }
      return
    } catch {
      diagnosticsLogger.error(
        "Diagnostics database open failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .milliseconds(250))
    timer.setEventHandler { [weak self] in self?.sample() }
    self.timer = timer
    timer.resume()
  }

  private func sample() {
    guard let physicalFootprintBytes = DiagnosticsProcessLoadSnapshot.capturePhysicalFootprint()
    else { return }
    let nowUptime = DispatchTime.now().uptimeNanoseconds
    let sample = DiagnosticsSampleFactory(
      launchID: launchID,
      launchUptimeNanoseconds: launchUptimeNanoseconds
    ).makeSample(
      uptimeNanoseconds: nowUptime,
      date: Date(),
      thermalState: ProcessInfo.processInfo.thermalState.rawValue,
      physicalFootprintBytes: physicalFootprintBytes
    )
    if let samples = sampleBuffer.append(sample) { write(samples) }
  }

  private func flush() {
    let samples = sampleBuffer.drain()
    write(samples)
  }

  private func write(_ samples: [DiagnosticsLoadSample]) {
    guard !samples.isEmpty else { return }
    do {
      try database?.insert(samples)
    } catch {
      diagnosticsLogger.error(
        "Diagnostics samples were discarded: \(error.localizedDescription, privacy: .public)")
    }
  }
}

struct DiagnosticsSampleBuffer {
  private let capacity: Int
  private var samples: [DiagnosticsLoadSample] = []

  init(capacity: Int) { self.capacity = capacity }

  mutating func append(_ sample: DiagnosticsLoadSample) -> [DiagnosticsLoadSample]? {
    samples.append(sample)
    guard samples.count >= capacity else { return nil }
    return drain()
  }

  mutating func drain() -> [DiagnosticsLoadSample] {
    let drained = samples
    samples.removeAll(keepingCapacity: true)
    return drained
  }
}

struct DiagnosticsSampleFactory {
  var launchID: UUID
  var launchUptimeNanoseconds: UInt64

  func makeSample(
    uptimeNanoseconds: UInt64,
    date: Date,
    thermalState: Int,
    physicalFootprintBytes: UInt64
  ) -> DiagnosticsLoadSample {
    return DiagnosticsLoadSample(
      sampledAtUnixMilliseconds: Int64((date.timeIntervalSince1970 * 1_000).rounded()),
      launchID: launchID,
      uptimeMilliseconds: Int64(
        (uptimeNanoseconds >= launchUptimeNanoseconds
          ? uptimeNanoseconds - launchUptimeNanoseconds : 0) / 1_000_000),
      physicalFootprintBytes: Int64(clamping: physicalFootprintBytes),
      thermalState: thermalState
    )
  }
}

struct DiagnosticsProcessLoadSnapshot {
  static func capturePhysicalFootprint() -> UInt64? {
    var vmInfo = task_vm_info_data_t()
    var vmCount = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let vmResult = withUnsafeMutablePointer(to: &vmInfo) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
      }
    }
    guard vmResult == KERN_SUCCESS else { return nil }
    return vmInfo.phys_footprint
  }
}
