// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceBundleFormat
import Testing

@Suite("Workspace bundle format")
struct WorkspaceBundleFormatIntegrationTestSuite {
  @Test("Writer initialization creates XML Info.plist metadata")
  func writerInitializationCreatesXMLInfoPlist() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)

    let writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    #expect(writer.bundleURL == packageURL)
    let infoData = try Data(contentsOf: packageURL.appendingPathComponent("Info.plist"))
    let infoXML = String(decoding: infoData, as: UTF8.self)
    #expect(infoXML.hasPrefix("<?xml"))
    #expect(try WorkspaceBundleValidatorV4(at: packageURL).validate() == "4.0")
  }

  @Test("generates a UUID version 7 identifier")
  func generatesUUIDv7WhenWritingDefinition() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    let identifier = writer.makeExternalID()
    #expect(
      try writer.write(
        definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4(), externalID: identifier) == identifier
    )

    #expect(identifier.uuidString.lowercased().split(separator: "-")[2].first == "7")
  }

  @Test("writes protobuf documents and format metadata")
  func writesProtobufOnlyPackage() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)

    let workspace = makeWorkspace()
    let reader = WorkspaceBundleReaderV4(at: packageURL)
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    try writeWorkspace(workspace, using: &writer)

    #expect(try reader.read() == workspace)
    let infoData = try Data(contentsOf: packageURL.appendingPathComponent("Info.plist"))
    let info = try #require(
      PropertyListSerialization.propertyList(
        from: infoData, options: .init(), format: nil)
        as? [String: Any])
    #expect(info["CFBundlePackageType"] as? String == "BNDL")
    #expect(info["LDTXWorkspaceVersion"] as? Int == 4)
    #expect(info["LDTXWorkspaceBundleVersion"] as? String == "4.0")
    #expect(try WorkspaceBundleValidatorV4(at: packageURL).validate() == "4.0")
    let selectedReader = makeWorkspaceBundleReader(at: packageURL)
    guard case .v4(let v4Reader) = selectedReader else {
      Issue.record("Expected the V4 reader")
      return
    }
    #expect(try v4Reader.read() == workspace)
    #expect(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent("definition.pb").path
      ))
    #expect(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(
          "preferences.pb"
        ).path
      ))
  }

  @Test("Reader gates decoded documents on Workspace integrity diagnostics")
  func readerValidatesWorkspaceIntegrity() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    var invalidDefinition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var invalidComponent = Ldtx_Workspace_V4_FillSolidColorComponent()
    invalidComponent.internalID = 0
    var componentWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    componentWrapper.videoComponent = .solidColorFill(invalidComponent)
    invalidDefinition.videoComponents = [componentWrapper]
    let definitionID = writer.makeExternalID()
    let preferencesID = writer.makeExternalID()
    #expect(
      try writer.write(definition: invalidDefinition, externalID: definitionID) == definitionID)
    #expect(
      try writer.write(
        preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4(), externalID: preferencesID)
        == preferencesID
    )

    try writer.write(outputSettings: .init(), externalID: writer.makeExternalID())
    #expect(throws: WorkspaceV4ValidationError.self) {
      try WorkspaceBundleReaderV4(at: packageURL).read()
    }
  }

  @Test("refuses to open a package in an unsupported format")
  func rejectsUnsupportedFormat() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try Data("{}".utf8).write(
      to: packageURL.appendingPathComponent("workspace.json")
    )

    #expect(readerFactoryFailed(at: packageURL))
  }

  @Test("factory selects Reader from logical Workspace version")
  func factorySelectsReaderFromWorkspaceVersion() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try writeFormatInfo(to: packageURL, version: 5)
    try Data().write(to: packageURL.appendingPathComponent("definition.pb"))
    try Data().write(to: packageURL.appendingPathComponent("preferences.pb"))

    #expect(readerFactoryFailed(at: packageURL))
  }

  @Test("rejects V4 metadata with an incorrect bundle package type")
  func rejectsIncorrectBundlePackageType() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundlePackageType": "APPL",
        "LDTXWorkspaceVersion": 4,
        "LDTXWorkspaceBundleVersion": "4.0",
      ],
      format: .xml,
      options: 0
    )
    try infoData.write(to: packageURL.appendingPathComponent("Info.plist"))

    guard case .v4(let reader) = makeWorkspaceBundleReader(at: packageURL) else {
      Issue.record("Expected the V4 reader selected by bundle version")
      return
    }
    #expect(throws: CocoaError.self) {
      try reader.read()
    }
  }

  @Test("Reader ignores the bundle version value", arguments: ["4.0", "4.1", "99.0"])
  func readerIgnoresBundleVersion(bundleVersion: String) throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    let workspace = makeWorkspace()
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    try writeWorkspace(workspace, using: &writer)
    try writeFormatInfo(to: packageURL, bundleVersion: bundleVersion)
    #expect(try WorkspaceBundleReaderV4(at: packageURL).read() == workspace)
  }

  @Test("Reader ignores missing and non-string bundle versions", arguments: [false, true])
  func readerIgnoresUnusableBundleVersion(includeValue: Bool) throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    let workspace = makeWorkspace()
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    try writeWorkspace(workspace, using: &writer)
    var info: [String: Any] = ["CFBundlePackageType": "BNDL", "LDTXWorkspaceVersion": 4]
    if includeValue { info["LDTXWorkspaceBundleVersion"] = 4.0 }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: packageURL.appendingPathComponent("Info.plist"))
    #expect(try WorkspaceBundleReaderV4(at: packageURL).read() == workspace)
  }

  @Test("requires a declared format version")
  func requiresFormatVersion() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try Data().write(to: packageURL.appendingPathComponent("definition.pb"))
    try Data().write(to: packageURL.appendingPathComponent("preferences.pb"))

    #expect(readerFactoryFailed(at: packageURL))
  }

  @Test("rejects a protobuf package containing a legacy preferences mirror")
  func rejectsMixedPackage() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    let reader = WorkspaceBundleReaderV4(at: packageURL)
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    try writeWorkspace(makeWorkspace(), using: &writer)
    try Data("{}".utf8).write(
      to: packageURL.appendingPathComponent("preferences.json"))

    #expect(throws: CocoaError.self) {
      try reader.read()
    }
    guard case .v4 = makeWorkspaceBundleReader(at: packageURL) else {
      Issue.record("Expected the V4 reader from Info.plist")
      return
    }
  }

  @Test("recognizes a malformed protobuf-only package as a V4 candidate")
  func recognizesMalformedV4Candidate() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try writeFormatInfo(to: packageURL)
    try Data().write(to: packageURL.appendingPathComponent("definition.pb"))
    try Data().write(
      to: packageURL.appendingPathComponent("preferences.pb"))

    let selectedReader = makeWorkspaceBundleReader(at: packageURL)
    guard case .v4(let reader) = selectedReader else {
      Issue.record("Expected the V4 reader")
      return
    }
    #expect(throws: Error.self) {
      try reader.read()
    }
  }

  @Test("reader factory reports a missing package metadata file")
  func readerFactoryRejectsMissingPackage() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let missingURL = rootURL.appendingPathComponent("Missing.ldtxworkspace", isDirectory: true)
    #expect(readerFactoryFailed(at: missingURL))
  }

  @Test("package writer persists the independent output settings envelope")
  func outputSettingsRoundTrip() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Workspace.ldtxworkspace")
    let workspace = makeWorkspace()
    try WorkspaceBundleWriterV4().write(workspace, to: destination)
    #expect(try WorkspaceBundleReaderV4(at: destination).read() == workspace)
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("output_settings.pb").path))
  }

  @Test(
    arguments: [0, 1, 2],
    [
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-7000-0000-000000000001",
      "00000000-0000-0000-0000-000000000000",
    ])
  func packageWriterRejectsInvalidEnvelopeIDs(document: Int, identifier: String) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Invalid.ldtxworkspace")
    var workspace = makeWorkspace()
    switch document {
    case 0: workspace.definitionExternalID = identifier
    case 1: workspace.preferencesExternalID = identifier
    default: workspace.outputSettingsExternalID = identifier
    }
    #expect(throws: WorkspaceV4ValidationError.self) {
      try WorkspaceBundleWriterV4().write(workspace, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test(
    arguments: [0, 1, 2],
    [
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-7000-0000-000000000001",
      "00000000-0000-0000-0000-000000000000",
    ])
  func lowLevelWriterRejectsInvalidIDs(document: Int, identifier: String) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try #require(WorkspaceBundleWriterV4(at: root))
    let id = try #require(UUID(uuidString: identifier))
    #expect(throws: CocoaError(.fileWriteInvalidFileName)) {
      switch document {
      case 0: _ = try writer.write(definition: .init(), externalID: id)
      case 1: _ = try writer.write(preferences: .init(), externalID: id)
      default: _ = try writer.write(outputSettings: .init(), externalID: id)
      }
    }
    for url in [try writer.definitionURL, try writer.preferencesURL, try writer.outputSettingsURL] {
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("Saving uses assigned model IDs and clearing retains model resources")
  func savesExternalModelReference() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Original.mlmodel")
    let data = Data([0, 1, 255])
    try data.write(to: source)
    var workspace = makeWorkspace()
    for id: Int64 in [5, 7] {
      workspace.definition.visions.append(
        .with {
          $0.ldtxSceneDetectorVision = .with {
            $0.internalID = id
            $0.displayName = "Classifier \(id)"
            $0.videoComponentInternalID = 2
            $0.modelInternalID = 9
          }
        })
    }
    workspace.visionModels = [9: source]
    let bundle = root.appendingPathComponent("Workspace.ldtxworkspace")
    try WorkspaceBundleWriterV4().write(workspace, to: bundle)
    #expect(workspace.visionModels[9] == source)
    let embedded = bundle.appendingPathComponent("VisionModels/9/Original.mlmodel")
    #expect(try Data(contentsOf: embedded) == data)
    let loaded = try WorkspaceBundleReaderV4(at: bundle).read()
    #expect(loaded.definition == workspace.definition)
    #expect(Set(loaded.visionModels.keys) == [9])
    #expect(loaded.visionModels[9]?.resolvingSymlinksInPath() == embedded.resolvingSymlinksInPath())
    var cleared = loaded
    cleared.definition.visions[1].ldtxSceneDetectorVision.modelInternalID = 0
    try WorkspaceBundleWriterV4().write(cleared, to: bundle)
    #expect(try Data(contentsOf: embedded) == data)
    #expect(try WorkspaceBundleReaderV4(at: bundle).read().visionModels == loaded.visionModels)
  }

  @Test("Model packages copy their native directory tree through save and reload")
  func nativeModelPackageRoundTrip() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Classifier.mlpackage")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Data"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: source.appendingPathComponent("Manifest.json"))
    try Data([1, 2, 3]).write(to: source.appendingPathComponent("Data/model.bin"))
    var workspace = makeWorkspace()
    workspace.visionModels = [9: source]
    let bundle = root.appendingPathComponent("Workspace.ldtxworkspace")
    try WorkspaceBundleWriterV4().write(workspace, to: bundle)
    let loaded = try WorkspaceBundleReaderV4(at: bundle).read()
    let embedded = try #require(loaded.visionModels[9])
    #expect(embedded.lastPathComponent == "Classifier.mlpackage")
    #expect(
      try Data(contentsOf: embedded.appendingPathComponent("Data/model.bin")) == Data([1, 2, 3]))
    let copied = root.appendingPathComponent("Copy.ldtxworkspace")
    try WorkspaceBundleWriterV4().write(loaded, to: copied)
    #expect(
      try Data(
        contentsOf: copied.appendingPathComponent(
          "VisionModels/9/Classifier.mlpackage/Data/model.bin")) == Data([1, 2, 3]))
  }

  @Test("The first supported basename is selected and existing models stay immutable")
  func selectsFirstModelWithinID() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Z.mlmodel")
    try Data([1]).write(to: source)
    var workspace = makeWorkspace()
    workspace.definition.visions.append(
      .with {
        $0.ldtxSceneDetectorVision = .with {
          $0.internalID = 5
          $0.displayName = "Classifier"
          $0.videoComponentInternalID = 2
          $0.modelInternalID = 9
        }
      })
    workspace.visionModels = [9: source]
    let bundle = root.appendingPathComponent("Workspace.ldtxworkspace")
    try WorkspaceBundleWriterV4().write(workspace, to: bundle)
    let first = bundle.appendingPathComponent("VisionModels/9/A.mlmodel")
    try Data([2]).write(to: first)
    try Data([3]).write(to: bundle.appendingPathComponent("VisionModels/9/000.txt"))
    let loaded = try WorkspaceBundleReaderV4(at: bundle).read()
    #expect(loaded.visionModels[9]?.resolvingSymlinksInPath() == first.resolvingSymlinksInPath())
    #expect(
      WorkspaceModelFiles.modelURL(
        for: workspace.definition.visions.last!.ldtxSceneDetectorVision,
        in: loaded.visionModels)?.resolvingSymlinksInPath() == first.resolvingSymlinksInPath())
    try Data([99]).write(to: source)
    try WorkspaceBundleWriterV4().write(workspace, to: bundle)
    #expect(
      try Data(contentsOf: bundle.appendingPathComponent("VisionModels/9/Z.mlmodel")) == Data([1]))
    #expect(try Data(contentsOf: first) == Data([2]))
  }

  @Test("Invalid or missing model references fail before changing the destination")
  func invalidModelReferencesDoNotWrite() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var workspace = makeWorkspace()
    workspace.definition.visions.append(
      .with {
        $0.ldtxSceneDetectorVision = .with {
          $0.internalID = 5
          $0.displayName = "Classifier"
          $0.videoComponentInternalID = 2
          $0.modelInternalID = 9
        }
      })
    let bundle = root.appendingPathComponent("Invalid.ldtxworkspace")
    #expect(throws: (any Error).self) { try WorkspaceBundleWriterV4().write(workspace, to: bundle) }
    workspace.visionModels[9] = root.appendingPathComponent("Missing.mlmodel")
    #expect(throws: (any Error).self) { try WorkspaceBundleWriterV4().write(workspace, to: bundle) }
    #expect(!FileManager.default.fileExists(atPath: bundle.path))
    let source = root.appendingPathComponent("Valid.mlmodel")
    try Data([1]).write(to: source)
    workspace.visionModels = [-1: source]
    #expect(throws: (any Error).self) { try WorkspaceBundleValidatorV4.validate(workspace) }
  }

  @Test("Model resources reject unsupported types, incomplete packages and symlinks")
  func rejectsUnsafeModelSources() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var workspace = makeWorkspace()
    let unsupported = root.appendingPathComponent("Classifier.txt")
    try Data([1]).write(to: unsupported)
    workspace.visionModels = [9: unsupported]
    #expect(throws: (any Error).self) { try WorkspaceBundleValidatorV4.validate(workspace) }
    let directory = root.appendingPathComponent("Directory.mlmodel")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    workspace.visionModels = [9: directory]
    #expect(throws: (any Error).self) { try WorkspaceBundleValidatorV4.validate(workspace) }
    let package = root.appendingPathComponent("Classifier.mlpackage")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    workspace.visionModels = [9: package]
    #expect(throws: (any Error).self) { try WorkspaceBundleValidatorV4.validate(workspace) }
    try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
    try FileManager.default.createSymbolicLink(
      at: package.appendingPathComponent("outside"), withDestinationURL: unsupported)
    #expect(throws: (any Error).self) { try WorkspaceBundleValidatorV4.validate(workspace) }
  }

  @Test("Model resources reject symlink destination directories")
  func rejectsUnsafeModelDestinations() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Classifier.mlmodel")
    try Data([1]).write(to: source)
    var workspace = makeWorkspace()
    workspace.visionModels = [9: source]
    let outside = root.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let bundle = root.appendingPathComponent("Workspace.ldtxworkspace")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let models = bundle.appendingPathComponent("VisionModels")
    try FileManager.default.createSymbolicLink(at: models, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try WorkspaceBundleWriterV4().write(workspace, to: bundle) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    try FileManager.default.removeItem(at: models)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: models.appendingPathComponent("9"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try WorkspaceBundleWriterV4().write(workspace, to: bundle) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  private func makeWorkspace() -> WorkspaceV4Bundle {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = "Unite"
    definition.audioDevices = [
      .with {
        $0.internalID = 1
        $0.displayName = "Microphone"
      }
    ]
    definition.videoComponents = [
      .with {
        $0.vfxSource = .with {
          $0.internalID = 2
          $0.displayName = "Camera"
        }
      }
    ]
    definition.visions = [
      .with {
        $0.ocrVision = .with {
          $0.internalID = 3
          $0.displayName = "OCR"
          $0.videoComponentInternalID = 2
        }
      }
    ]
    definition.canvasConfiguration.ptsMasterVfxSourceInternalID = 2
    return WorkspaceV4Bundle(
      definitionExternalID: "0198f4b4-1fa3-7000-8000-000000000001",
      preferencesExternalID: "0198f4b4-1fa3-7000-8000-000000000002",
      definition: definition,
      preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4(),
      outputSettingsExternalID: "0198f4b4-1fa3-7000-8000-000000000003",
      outputSettings: .with {
        $0.recordingEnabled = true
        $0.recordingSettings.recordsLandscape = true
        $0.recordingSettings.customFields["game"] = "Unite"
      }
    )
  }

  private func writeWorkspace(
    _ workspace: WorkspaceV4Bundle, using writer: inout WorkspaceBundleWriterV4
  )
    throws
  {
    let definitionExternalID =
      try workspace.definitionExternalID.map {
        try #require(UUID(uuidString: $0))
      } ?? writer.makeExternalID()
    let preferencesExternalID =
      try workspace.preferencesExternalID.map {
        try #require(UUID(uuidString: $0))
      } ?? writer.makeExternalID()
    #expect(
      try writer.write(definition: workspace.definition, externalID: definitionExternalID)
        == definitionExternalID
    )
    #expect(
      try writer.write(preferences: workspace.preferences, externalID: preferencesExternalID)
        == preferencesExternalID
    )
    let outputIDString = try #require(workspace.outputSettingsExternalID)
    let outputID = try #require(UUID(uuidString: outputIDString))
    #expect(
      try writer.write(outputSettings: workspace.outputSettings, externalID: outputID) == outputID)
    #expect(definitionExternalID.uuidString.lowercased() == workspace.definitionExternalID)
    #expect(preferencesExternalID.uuidString.lowercased() == workspace.preferencesExternalID)
  }

  private func readerFactoryFailed(at bundleURL: URL) -> Bool {
    if case .failure = makeWorkspaceBundleReader(at: bundleURL) { return true }
    return false
  }

  private func writeFormatInfo(
    to bundleURL: URL,
    version: Int = 4,
    bundleVersion: String = "4.0"
  ) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundlePackageType": "BNDL",
        "LDTXWorkspaceVersion": version,
        "LDTXWorkspaceBundleVersion": bundleVersion,
      ],
      format: .xml,
      options: 0
    )
    try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
