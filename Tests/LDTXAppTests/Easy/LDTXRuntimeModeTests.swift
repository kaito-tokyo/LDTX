// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecording
import Testing

@testable import LDTXAppCore

struct LDTXRuntimeModeTests {
  @Test(arguments: [
    (unitTesting: true, uiTesting: false, preview: false),
    (unitTesting: false, uiTesting: true, preview: false),
    (unitTesting: false, uiTesting: false, preview: true),
  ])
  func diagnosticsAreDisabledInTestAndPreviewModes(
    unitTesting: Bool,
    uiTesting: Bool,
    preview: Bool
  ) {
    #expect(
      !LDTXRuntimeMode.shouldEnableDiagnostics(
        unitTesting: unitTesting,
        uiTesting: uiTesting,
        preview: preview
      ))
  }

  @Test func diagnosticsAreEnabledForNormalApplicationLaunches() {
    #expect(
      LDTXRuntimeMode.shouldEnableDiagnostics(
        unitTesting: false,
        uiTesting: false,
        preview: false
      ))
  }

  @MainActor
  @Test func recordingDiagnosticsContextFollowsRuntimeMode() {
    let context = RecordingDiagnosticsContext(
      launchID: UUID(), launchUptimeNanoseconds: 123)
    let router = LDTXApplicationRouter(recordingDiagnosticsContext: context)

    #expect(router.recordingDiagnosticsContextIfEnabled(diagnosticsEnabled: true) == context)
    #expect(router.recordingDiagnosticsContextIfEnabled(diagnosticsEnabled: false) == nil)
  }
}
