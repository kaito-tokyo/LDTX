// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXProgram
import LDTXProgramRuntime

struct PrivateFailureSession: HTTPSession {
  func data(
    for request: URLRequest,
    completionHandler: @escaping @Sendable (Result<(Data, URLResponse), any Error>) -> Void
  ) {
    completionHandler(
      .failure(
        NSError(
          domain: "ISSUE220_PRIVATE_DOMAIN", code: 220,
          userInfo: [
            NSLocalizedDescriptionKey:
              "ISSUE220_PRIVATE_ERROR_OCR /Users/ISSUE220_PRIVATE_PATH/recording"
          ])))
  }
}
@main struct Probe {
  static func main() async throws {
    precondition(ProcessInfo.processInfo.environment["OS_ACTIVITY_DT_MODE"] == nil)
    let name = "ISSUE220_PRIVATE_STEP_OCR"
    let step = CompositeProgramStep(
      id: name, component: .inputCameraDevice(InputDeviceComponent(destinationX: 120)))
    let config = ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(steps: [step, step]), audioChannels: [],
      canvasWidth: 320, canvasHeight: 180, outputWidth: 320, outputHeight: 180, frameRate: 60,
      timeSeconds: 0, videoPTSMasterCameraID: nil, cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:], backgroundRemovalInputKeys: [])
    let state = ProgramRuntimeState()
    state.replace(with: config)
    precondition(state.read { $0?.composite.steps.count } == 1)
    let client = DASHUploadClient(
      endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://example.invalid/dash?file=")!),
      session: PrivateFailureSession(), retryPolicy: DASHRetryPolicy(maxAttempts: 1))
    do {
      let _: DASHUploadResponse = try await withCheckedThrowingContinuation { continuation in
        client.put(
          DASHUploadObject(
            name: DASHObjectName(rawValue: "ISSUE220_PRIVATE_OBJECT.mpd"),
            data: Data("<MPD/>".utf8), contentType: "application/dash+xml")
        ) { continuation.resume(with: $0) }
      }
      fatalError("Expected failure")
    } catch {
      precondition((error as NSError).code == 220)
      precondition(error.localizedDescription.contains("ISSUE220_PRIVATE_ERROR"))
    }
    print("Production log probe passed pid=\(ProcessInfo.processInfo.processIdentifier)")
  }
}
