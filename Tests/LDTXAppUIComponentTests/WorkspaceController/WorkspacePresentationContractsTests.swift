// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite @MainActor
  struct WorkspacePresentationContractsIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("Model information is requested through the injected reader")
    func modelInformationUsesInjectedReader() async throws {
      let url = URL(fileURLWithPath: "/tmp/ModelInformation-\(UUID()).mlpackage")
      var requests: [URL] = []
      let inspector = LdtxSceneDetectorVisionInspector(
        videoComponents: [], inputSize: nil, vision: .constant(.init()),
        modelURL: .constant(url),
        readModelInformation: { requestedURL in
          requests.append(requestedURL)
          return WorkspaceVisionModelInformation(
            cropAndScaleAction: .scaleToFit, author: "Contract fixture",
            inputWidth: 320, inputHeight: 240)
        })
      let window = hostWorkspaceView(inspector)
      defer { window.close() }
      for _ in 0..<100 where requests.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(requests == [url])
    }
  }
}
