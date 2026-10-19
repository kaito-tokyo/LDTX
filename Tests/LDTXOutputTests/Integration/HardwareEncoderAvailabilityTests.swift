// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import Testing
import VideoToolbox

extension OutputTestSuite {
  @Suite
  struct HardwareEncoderAvailabilityIntegrationTestSuite {
    @Test(arguments: [false, true])
    func singleDualAndReleasedHardwareEncoders(workspaceSize: Bool) async {
      let sizes = workspaceSize ? [(1920, 1080), (1080, 1920)] : [(16, 16), (16, 16)]
      let profile = workspaceSize ? "workspace" : "tiny"
      print(
        "[encoder-probe] profile=\(profile) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
      )
      var list: CFArray?
      let status = VTCopyVideoEncoderList(nil, &list)
      print("[encoder-probe] enumerationStatus=\(status)")
      for entry in list as? [[String: Any]] ?? [] {
        guard
          (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
            == kCMVideoCodecType_H264
        else { continue }
        let id = entry[kVTVideoEncoderList_EncoderID as String] as? String ?? "unknown"
        let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?
          .boolValue
        // Only framework identifiers and capabilities, never host names, devices or paths.
        print("[encoder-probe] encoderID=\(id) hardware=\(String(describing: hardware))")
      }
      #expect(status == noErr)

      for (phase, count) in [("single-before", 1), ("dual", 2), ("single-after-release", 1)] {
        var encoders: [H264VideoEncoder] = []
        for index in 0..<count {
          let (width, height) = sizes[index]
          let started = ContinuousClock.now
          print(
            "[encoder-probe] profile=\(profile) phase=\(phase) index=\(index) create width=\(width) height=\(height) live=\(encoders.count)"
          )
          do {
            let encoder = try H264VideoEncoder(
              configuration: .init(
                width: width, height: height, frameRate: 30, bitRate: 1_000_000,
                requiresHardwareAcceleration: true)
            ) { result in
              if case .failure(let error) = result { Issue.record(error) }
            }
            encoders.append(encoder)
            print(
              "[encoder-probe] profile=\(profile) phase=\(phase) index=\(index) created elapsed=\(started.duration(to: .now))"
            )
          } catch {
            print(
              "[encoder-probe] profile=\(profile) phase=\(phase) index=\(index) failed error=\(error)"
            )
            Issue.record(error)
          }
        }
        #expect(encoders.count == count)
        for (index, encoder) in encoders.enumerated() {
          do {
            try await withCheckedThrowingContinuation {
              (continuation: CheckedContinuation<Void, any Error>) in
              encoder.finish { continuation.resume(with: $0) }
            }
            print(
              "[encoder-probe] profile=\(profile) phase=\(phase) index=\(index) finished-and-invalidated"
            )
          } catch {
            print(
              "[encoder-probe] profile=\(profile) phase=\(phase) index=\(index) finish-failed error=\(error)"
            )
            Issue.record(error)
          }
        }
        encoders.removeAll()
      }
    }
  }
}
