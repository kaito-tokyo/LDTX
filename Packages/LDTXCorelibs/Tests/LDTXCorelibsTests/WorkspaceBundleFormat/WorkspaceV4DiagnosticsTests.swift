// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import Testing

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite("Workspace persistence diagnostics")
struct WorkspaceV4DiagnosticsIntegrationTestSuite {
  private func invalidWorkspace() -> WorkspaceV4Bundle {
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.visions = [
        .with {
          $0.vision = .ocrVision(
            .with {
              $0.internalID = 11
              $0.displayName = "OCR"
              $0.videoComponentInternalID = 99
              $0.regionOfInterest = .with {
                $0.x = .with { $0.set(num: 0, den: 0) }
                $0.y = .with { $0.set(num: 1, den: 0) }
                $0.width = .with { $0.set(num: -1, den: 1) }
                $0.height = .with { $0.set(num: 2, den: 1) }
              }
              $0.triggers = [
                .with {
                  $0.trigger = .intervalTrigger(
                    .with { $0.intervalSeconds = .with { $0.set(num: 0, den: 0) } })
                }
              ]
            })
        }
      ]
    }
    return .init(definition: definition, preferences: .init())
  }

  @Test(
    "LUB-1002: Independent violations are collected without deriving errors from invalid fractions")
  func allFieldsAndNoCorrection() {
    let workspace = invalidWorkspace()
    let issues = WorkspaceBundleValidatorV4.validationIssues(in: workspace)
    #expect(issues.count == 6)
    #expect(issues.allSatisfy { $0.entityID == 11 })
    #expect(issues.filter { $0.error == .invalidRational }.count == 3)
    #expect(
      issues.contains { $0.path == "definition.visions[0].ocr_vision.region_of_interest.x.den" })
    #expect(!issues.contains { $0.path.contains("+") })
    guard case .ocrVision(let vision) = workspace.definition.visions[0].vision else {
      Issue.record("Expected OCR vision")
      return
    }
    #expect(vision.regionOfInterest?.x?.den == 0)
  }

  @Test("LUB-1002: Defaults remain valid but explicitly zero denominators fail")
  func defaultsAndZero() throws {
    try WorkspaceBundleValidatorV4.validateRegionOfInterest(.init())
    let region = Ldtx_Workspace_V4_VisionRegionOfInterest.with {
      $0.x = .with { $0.set(num: 0, den: 0) }
      $0.y = .with { $0.set(num: 0, den: 0) }
    }
    do {
      try WorkspaceBundleValidatorV4.validateRegionOfInterest(region)
      Issue.record("Expected diagnostics")
    } catch let error as WorkspaceV4ValidationError {
      #expect(
        error.diagnostics.map(\.path) == ["region_of_interest.x.den", "region_of_interest.y.den"])
      #expect(error.localizedDescription.contains("region_of_interest.x.den"))
      #expect(error.localizedDescription.contains("region_of_interest.y.den"))
    }
  }

  @Test("LUB-1002: Write rejects all violations before creating or changing the destination")
  func writeGate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = invalidWorkspace()
    #expect(
      performing: {
        try WorkspaceBundleWriterV4().write(invalid, to: root)
      }, throws: { ($0 as? WorkspaceV4ValidationError)?.diagnostics.count == 6 })
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let valid = WorkspaceV4Bundle(definition: .init(), preferences: .init())
    try WorkspaceBundleWriterV4().write(valid, to: root)
    let before = try Data(contentsOf: root.appendingPathComponent("definition.pb"))
    #expect(throws: WorkspaceV4ValidationError.self) {
      try WorkspaceBundleWriterV4().write(invalid, to: root)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent("definition.pb")) == before)
  }

  @Test("LUB-1002: Read rejects corrupt content with the same full diagnostic array as Write")
  func readGate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try WorkspaceBundleWriterV4().write(.init(definition: .init(), preferences: .init()), to: root)
    let invalid = invalidWorkspace()
    let rawWriter = try #require(WorkspaceBundleWriterV4(at: root))
    _ = try rawWriter.write(
      definition: invalid.definition, externalID: WorkspaceBundleWriterV4.makeExternalID())
    #expect(
      performing: {
        try WorkspaceBundleReaderV4(at: root).read()
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics
          == WorkspaceBundleValidatorV4.validationIssues(in: invalid)
      })
  }

  @Test(
    "LUB-1002: Model reference and file violations are collected alongside definition violations")
  func modelDiagnostics() {
    var workspace = invalidWorkspace()
    workspace.visionModels = [-1: URL(fileURLWithPath: "/nonexistent/Invalid.txt")]
    workspace.definition.visions.append(
      .with {
        $0.vision = .ldtxSceneDetectorVision(
          .with {
            $0.internalID = 13
            $0.displayName = "Detector"
            $0.videoComponentInternalID = 99
            $0.modelInternalID = 17
          })
      })
    let issues = WorkspaceBundleValidatorV4.validationIssues(in: workspace)
    #expect(issues.contains { $0.error == .invalidModelID(-1) })
    #expect(issues.contains { $0.error == .missingVisionModel(17) && $0.entityID == 13 })
    #expect(
      issues.contains { issue in
        guard issue.path == "visionModels[-1]" else { return false }
        if case .invalidModelResource = issue.error { return true }
        return false
      })
  }

  @Test("LUB-1002: Every duplicate resource and invalid envelope is identified")
  func duplicateLocationsAndEnvelopes() {
    var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
    workspace.definition.programs = (0..<2).map { _ in
      .with {
        $0.internalID = 7
        $0.displayName = "Program"
      }
    }
    workspace.definitionExternalID = "invalid"
    workspace.preferencesExternalID = "invalid"
    let issues = WorkspaceBundleValidatorV4.validationIssues(in: workspace)
    #expect(
      issues.filter { $0.error == .duplicateInternalID }.map(\.path) == [
        "definition.programs[0].internal_id", "definition.programs[1].internal_id",
      ])
    #expect(issues.filter { $0.error == .duplicateDisplayName("Program") }.count == 2)
    #expect(
      issues.filter { $0.error == .invalidEnvelopeID }.map(\.path) == [
        "definitionExternalID", "preferencesExternalID",
      ])
  }
}
