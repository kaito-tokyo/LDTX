// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Darwin
import Foundation
import LDTXProtos
@testable import LDTXUtils
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat
import SwiftProtobuf
import Testing

@Suite("LDTX Workspace CLI commands", .serialized)
struct CommandsSystemTestSuite {
  @Test("parses the Workspace command tree")
  func parsesWorkspaceCommands() throws {
    #expect(
      try LdtxCLI.parseAsRoot(["workspace", "create", "new.ldtxworkspace"])
        is WorkspaceCommand.Create)
    #expect(
      try LdtxCLI.parseAsRoot(["workspace", "dump", "workspace.ldtxworkspace"])
        is WorkspaceCommand.Dump)
    #expect(
      try LdtxCLI.parseAsRoot(["workspace", "validate", "workspace.ldtxworkspace"])
        is WorkspaceCommand.Validate)
    #expect(throws: Error.self) {
      try LdtxCLI.parseAsRoot(["workspace", "unknown", "workspace.ldtxworkspace"])
    }
    #expect(throws: Error.self) { try LdtxCLI.parseAsRoot(["workspace", "validate"]) }
  }

  @Test("creates a default Workspace package")
  func createsDefaultWorkspace() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Default.ldtxworkspace")
      let output = try await captureOutput {
        var command = try WorkspaceCommand.Create.parse([packageURL.path])
        try await command.run()
      }
      let workspace = try WorkspaceBundleReaderV4(at: packageURL).read()
      #expect(workspace.definition.displayName == "Default")
      #expect(output.stdout == "Created Workspace v4: \(packageURL.path)\n")
      #expect(output.stderr.isEmpty)
    }
  }

  @Test("creates a named Workspace package")
  func createsNamedWorkspace() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Workspace.ldtxworkspace")
      var command = try WorkspaceCommand.Create.parse([packageURL.path, "--name", "Studio"])
      try await command.run()
      #expect(
        try WorkspaceBundleReaderV4(at: packageURL).read().definition.displayName
          == "Studio")
    }
  }

  @Test("imports definition and preferences JSON")
  func importsJSON() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Imported.ldtxworkspace")
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.displayName = "From JSON"
      var importedProgram = Ldtx_Workspace_V4_ProgramDefinition()
      importedProgram.internalID = 42
      importedProgram.displayName = "Imported"
      definition.programs = [importedProgram]
      let definitionURL = root.appendingPathComponent("definition.json")
      try definition.jsonUTF8Data().write(to: definitionURL)
      var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
      preferences.landscapeProgramPreferences[42] = .init()
      let preferencesURL = root.appendingPathComponent("preferences.json")
      try preferences.jsonUTF8Data().write(to: preferencesURL)

      var command = try WorkspaceCommand.Create.parse([
        packageURL.path, "--json", definitionURL.path, "--preferences-json", preferencesURL.path,
        "--name", "Overridden",
      ])
      try await command.run()
      let workspace = try WorkspaceBundleReaderV4(at: packageURL).read()
      #expect(workspace.definition.displayName == "Overridden")
      #expect(workspace.preferences.landscapeProgramPreferences[42] != nil)
    }
  }

  @Test("rejects preferences JSON without definition JSON")
  func rejectsPreferencesWithoutDefinition() async throws {
    var command = try WorkspaceCommand.Create.parse([
      "workspace.ldtxworkspace", "--preferences-json", "preferences.json",
    ])
    #expect(await asyncThrows { try await command.run() })
  }

  @Test("does not overwrite an existing package without replace")
  func rejectsExistingPackage() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Existing.ldtxworkspace")
      try writeWorkspace(makeWorkspace(displayName: "Original"), to: packageURL)
      var command = try WorkspaceCommand.Create.parse([packageURL.path])
      #expect(await asyncThrows { try await command.run() })
      #expect(
        try WorkspaceBundleReaderV4(at: packageURL).read().definition.displayName
          == "Original")
    }
  }

  @Test("replaces an existing package with replace")
  func replacesExistingPackage() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Existing.ldtxworkspace")
      try writeWorkspace(makeWorkspace(displayName: "Original"), to: packageURL)
      var command = try WorkspaceCommand.Create.parse([
        packageURL.path, "--name", "Replacement", "--replace",
      ])
      try await command.run()
      #expect(
        try WorkspaceBundleReaderV4(at: packageURL).read().definition.displayName
          == "Replacement")
    }
  }

  @Test("removes a partially created package when import fails")
  func removesFailedImport() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Broken.ldtxworkspace")
      let definitionURL = root.appendingPathComponent("broken.json")
      try Data("not-json".utf8).write(to: definitionURL)
      var command = try WorkspaceCommand.Create.parse([
        packageURL.path, "--json", definitionURL.path,
      ])
      #expect(await asyncThrows { try await command.run() })
      #expect(!FileManager.default.fileExists(atPath: packageURL.path))
    }
  }

  @Test("dumps all Programs and filters by name")
  func dumpsWorkspace() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Programs.ldtxworkspace")
      try writeWorkspace(makeWorkspaceWithPrograms(), to: packageURL)
      let all = try await captureOutput {
        var command = try WorkspaceCommand.Dump.parse([packageURL.path])
        try command.run()
      }
      let filtered = try await captureOutput {
        var command = try WorkspaceCommand.Dump.parse([packageURL.path, "--program", "Portrait"])
        try command.run()
      }
      let allJSON = try #require(
        JSONSerialization.jsonObject(with: Data(all.stdout.utf8)) as? [String: Any])
      let programs = try #require(allJSON["programs"] as? [[String: Any]])
      #expect(programs.count == 2)
      #expect(all.stdout.contains("\n  \"format\" : \"ldtx-workspace-debug-dump-v4\""))
      let filteredJSON = try #require(
        JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [String: Any])
      let filteredPrograms = try #require(filteredJSON["programs"] as? [[String: Any]])
      #expect(filteredPrograms.count == 1)
      #expect(filteredPrograms[0]["displayName"] as? String == "Portrait")
    }
  }

  @Test("dump rejects an unknown Program")
  func rejectsUnknownProgram() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Programs.ldtxworkspace")
      try writeWorkspace(makeWorkspaceWithPrograms(), to: packageURL)
      var command = try WorkspaceCommand.Dump.parse([packageURL.path, "--program", "Missing"])
      #expect(throws: Error.self) { try command.run() }
    }
  }

  @Test("validates a Workspace and preserves its files")
  func validatesWorkspace() async throws {
    try await withTemporaryDirectory { root in
      let packageURL = root.appendingPathComponent("Valid.ldtxworkspace")
      try writeWorkspace(makeWorkspace(displayName: "Valid"), to: packageURL)
      let before = try packageSnapshot(packageURL)
      let output = try await captureOutput {
        var command = try WorkspaceCommand.Validate.parse([packageURL.path])
        try command.run()
      }
      #expect(output.stdout == "OK: Workspace v4 \(packageURL.path)\n")
      #expect(try packageSnapshot(packageURL) == before)
    }
  }

  @Test("validate rejects malformed, legacy, invalid, and missing packages")
  func rejectsInvalidPackages() async throws {
    try await withTemporaryDirectory { root in
      let missing = root.appendingPathComponent("Missing.ldtxworkspace")
      var missingCommand = try WorkspaceCommand.Validate.parse([missing.path])
      #expect(throws: Error.self) { try missingCommand.run() }

      let legacy = root.appendingPathComponent("Legacy.ldtxworkspace")
      try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
      try Data("{}".utf8).write(
        to: legacy.appendingPathComponent("workspace.json"))
      var legacyCommand = try WorkspaceCommand.Validate.parse([legacy.path])
      #expect(throws: Error.self) { try legacyCommand.run() }

      let malformed = root.appendingPathComponent("Malformed.ldtxworkspace")
      try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
      try Data().write(
        to: malformed.appendingPathComponent("definition.pb"))
      try Data().write(
        to: malformed.appendingPathComponent("preferences.pb"))
      var malformedCommand = try WorkspaceCommand.Validate.parse([malformed.path])
      #expect(throws: Error.self) { try malformedCommand.run() }

      let invalid = root.appendingPathComponent("Invalid.ldtxworkspace")
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 1
      program.displayName = "Invalid"
      definition.programs = [program]
      try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
      let infoData = try PropertyListSerialization.data(
        fromPropertyList: [
          "CFBundlePackageType": "BNDL",
          "LDTXWorkspaceVersion": 4,
          "LDTXWorkspaceBundleVersion": "4.0",
        ],
        format: .xml,
        options: 0
      )
      try infoData.write(to: invalid.appendingPathComponent("Info.plist"))
      var definitionEnvelope = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
      definitionEnvelope.externalIDAsUUID = try #require(
        UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000001"))
      definitionEnvelope.workspaceDefinitionV4 = definition
      try definitionEnvelope.serializedData().write(
        to: invalid.appendingPathComponent("definition.pb"))
      var preferencesEnvelope = Ldtx_Envelope_WorkspacePreferencesEnvelope()
      preferencesEnvelope.externalIDAsUUID = try #require(
        UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000002"))
      preferencesEnvelope.workspacePreferencesV4 = .with {
        $0.landscapeProgramPreferences[1] = .with { $0.videoLayerInternalIds = [999] }
      }
      try preferencesEnvelope.serializedData().write(
        to: invalid.appendingPathComponent("preferences.pb"))
      var outputEnvelope = Ldtx_Envelope_WorkspaceOutputSettingsEnvelope()
      outputEnvelope.externalIDAsUUID = UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000003")
      outputEnvelope.workspaceOutputSettingsV4 = .init()
      try outputEnvelope.serializedData().write(
        to: invalid.appendingPathComponent("output_settings.pb"))
      var invalidCommand = try WorkspaceCommand.Validate.parse([invalid.path])
      #expect(throws: Error.self) { try invalidCommand.run() }
    }
  }

  private func makeWorkspace(displayName: String) -> WorkspaceV4Bundle {
    return WorkspaceV4Bundle(
      definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4.with { $0.displayName = displayName },
      preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
  }

  private func writeWorkspace(_ workspace: WorkspaceV4Bundle, to packageURL: URL) throws {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    var writer = try #require(WorkspaceBundleWriterV4(at: packageURL))
    let definitionExternalID = writer.makeExternalID()
    try writer.write(definition: workspace.definition, externalID: definitionExternalID)
    let preferencesExternalID = writer.makeExternalID()
    try writer.write(preferences: workspace.preferences, externalID: preferencesExternalID)
    try writer.write(outputSettings: workspace.outputSettings, externalID: writer.makeExternalID())
    #expect(definitionExternalID.uuidString.lowercased().split(separator: "-")[2].first == "7")
    #expect(preferencesExternalID.uuidString.lowercased().split(separator: "-")[2].first == "7")
  }

  private func makeWorkspaceWithPrograms() -> WorkspaceV4Bundle {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = "Programs"
    var firstLandscape = Ldtx_Workspace_V4_FillSolidColorComponent()
    firstLandscape.internalID = 10
    firstLandscape.displayName = "First landscape"
    var firstLandscapeWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    firstLandscapeWrapper.solidColorFill = firstLandscape
    var firstPortrait = Ldtx_Workspace_V4_FillSolidColorComponent()
    firstPortrait.internalID = 20
    firstPortrait.displayName = "First portrait"
    var firstPortraitWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    firstPortraitWrapper.solidColorFill = firstPortrait
    var secondLandscape = Ldtx_Workspace_V4_FillSolidColorComponent()
    secondLandscape.internalID = 30
    secondLandscape.displayName = "Second landscape"
    var secondLandscapeWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    secondLandscapeWrapper.solidColorFill = secondLandscape
    var secondPortrait = Ldtx_Workspace_V4_FillSolidColorComponent()
    secondPortrait.internalID = 40
    secondPortrait.displayName = "Second portrait"
    var secondPortraitWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    secondPortraitWrapper.solidColorFill = secondPortrait
    definition.videoComponents = [
      firstLandscapeWrapper, firstPortraitWrapper, secondLandscapeWrapper, secondPortraitWrapper,
    ]
    definition.programs = [
      .with {
        $0.internalID = 1
        $0.displayName = "Landscape"
      },
      .with {
        $0.internalID = 2
        $0.displayName = "Portrait"
      },
    ]
    let preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 = .with {
      $0.landscapeProgramPreferences[1] = .with { $0.videoLayerInternalIds = [10] }
      $0.portraitProgramPreferences[1] = .with { $0.videoLayerInternalIds = [20] }
      $0.landscapeProgramPreferences[2] = .with { $0.videoLayerInternalIds = [30] }
      $0.portraitProgramPreferences[2] = .with { $0.videoLayerInternalIds = [40] }
    }
    return WorkspaceV4Bundle(definition: definition, preferences: preferences)
  }

  private func packageSnapshot(_ packageURL: URL) throws -> [String: Data] {
    try [
      "definition.pb", "preferences.pb", "output_settings.pb",
    ]
    .reduce(into: [:]) { result, name in
      result[name] = try Data(contentsOf: packageURL.appendingPathComponent(name))
    }
  }

  private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let previousApplicationSupport = ProcessInfo.processInfo.environment["LDTX_APPLICATION_SUPPORT"]
    setenv("LDTX_APPLICATION_SUPPORT", url.path, 1)
    defer {
      if let previousApplicationSupport {
        setenv("LDTX_APPLICATION_SUPPORT", previousApplicationSupport, 1)
      } else {
        unsetenv("LDTX_APPLICATION_SUPPORT")
      }
      try? FileManager.default.removeItem(at: url)
    }
    return try await body(url)
  }
}

private struct CapturedOutput {
  var stdout: String
  var stderr: String
}

private func asyncThrows(_ body: () async throws -> Void) async -> Bool {
  do {
    try await body()
    return false
  } catch {
    return true
  }
}

private func captureOutput<T>(_ body: () async throws -> T) async throws -> CapturedOutput {
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  let stdout = dup(STDOUT_FILENO)
  let stderr = dup(STDERR_FILENO)
  dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
  dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
  func restore() {
    fflush(nil)
    dup2(stdout, STDOUT_FILENO)
    dup2(stderr, STDERR_FILENO)
    close(stdout)
    close(stderr)
  }
  do {
    _ = try await body()
  } catch {
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()
    restore()
    throw error
  }
  fflush(nil)
  stdoutPipe.fileHandleForWriting.closeFile()
  stderrPipe.fileHandleForWriting.closeFile()
  restore()
  return CapturedOutput(
    stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
    stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
