// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXWorkspace
import Testing

struct WorkspacePackageServiceTests {
  @MainActor
  @Test func saveWritesProtobufAndJSONAndLoadReadsProtobuf() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    let workspace = WorkspaceDefinition(
      name: "Package Workspace",
      programs: [
        SavedProgramDefinitionRecord(
          name: "Package Program",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition()
        )
      ],
      inputDevices: [
        WorkspaceInputDeviceRecord(
          id: "workspace-camera",
          name: "Game Capture",
          kind: .video,
        ),
        WorkspaceInputDeviceRecord(
          id: "workspace-game-audio",
          name: "Game Audio",
          kind: .audio,
        ),
      ]
    )

    try service.saveWorkspaceStore(try WorkspaceStore(clean: workspace), to: packageURL)

    #expect(
      fileManager.fileExists(
        atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName).path
      ))
    #expect(
      fileManager.fileExists(
        atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName).path
      ))
    #expect(try service.loadWorkspace(at: packageURL).definition == workspace)
  }

  @MainActor
  @Test func savePreservesWorkspaceDependenciesInPackage() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let assetsURL = packageURL.appendingPathComponent(WorkspacePackageLayout.assetsDirectoryName)
    let assetURL = assetsURL.appendingPathComponent("background.txt")
    try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    try Data("asset".utf8).write(to: assetURL)

    let service = WorkspacePackageService(fileManager: fileManager)
    try service.saveWorkspaceStore(
      try WorkspaceStore(clean: WorkspaceDefinition(name: "A")),
      to: packageURL
    )
    try service.saveWorkspaceStore(
      try WorkspaceStore(clean: WorkspaceDefinition(name: "B")),
      to: packageURL
    )

    #expect(try Data(contentsOf: assetURL) == Data("asset".utf8))
    #expect(try service.loadWorkspace(at: packageURL).definition.name == "B")
  }

  @MainActor
  @Test func saveKeepsWorkspacePackageVisible() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)

    try service.saveWorkspaceStore(
      try WorkspaceStore(clean: WorkspaceDefinition(name: "Initial")),
      to: packageURL
    )
    #expect(try packageURL.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)

    try service.saveWorkspaceStore(
      try WorkspaceStore(clean: WorkspaceDefinition(name: "Replacement")),
      to: packageURL
    )
    #expect(try packageURL.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
  }

  @MainActor
  @Test func applicationSupportBackupsShareLineageAndRetainNewestTenGenerations() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let backupsURL = root.appendingPathComponent("Application Support/WorkspaceBackups")
    let firstPackageURL = root.appendingPathComponent("First.ldtxworkspace")
    let copiedPackageURL = root.appendingPathComponent("Copied.ldtxworkspace")
    let lineageID = UUID()
    let backupService = WorkspaceBackupService(
      fileManager: fileManager,
      rootDirectoryURL: backupsURL,
      maximumGenerationCount: 10
    )
    let service = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService
    )

    for generation in 1...10 {
      try service.saveWorkspaceStore(
        try WorkspaceStore(
          clean: WorkspaceDefinition(
            lineageID: lineageID,
            name: "Generation \(generation)"
          )),
        to: firstPackageURL
      )
    }
    try fileManager.copyItem(at: firstPackageURL, to: copiedPackageURL)
    try service.saveWorkspaceStore(
      try WorkspaceStore(
        clean: WorkspaceDefinition(
          lineageID: lineageID,
          name: "Copied Generation"
        )),
      to: copiedPackageURL
    )

    let generationURLs = try backupService.generationPackageURLs(for: lineageID)
    #expect(generationURLs.count == 10)
    #expect(try service.loadWorkspace(at: firstPackageURL).definition.name == "Generation 10")
    #expect(try service.loadWorkspace(at: copiedPackageURL).definition.name == "Copied Generation")
    #expect(
      try generationURLs.contains {
        try service.loadWorkspace(at: $0).definition.name == "Copied Generation"
      })
  }

  @MainActor
  @Test func backedUpSavePreservesPackageDependenciesAndRemovesObsoleteArtifacts() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let assetsURL = packageURL.appendingPathComponent(WorkspacePackageLayout.assetsDirectoryName)
    let assetURL = assetsURL.appendingPathComponent("background.txt")
    let obsoleteLockURL = packageURL.appendingPathComponent("LDTX.lock")
    try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    try Data("asset".utf8).write(to: assetURL)
    try Data("obsolete".utf8).write(to: obsoleteLockURL)

    let backupService = WorkspaceBackupService(
      fileManager: fileManager,
      rootDirectoryURL: root.appendingPathComponent("Backups")
    )
    let service = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService
    )
    let workspace = WorkspaceDefinition(name: "Saved")

    try service.saveWorkspaceStore(try WorkspaceStore(clean: workspace), to: packageURL)

    #expect(try Data(contentsOf: assetURL) == Data("asset".utf8))
    #expect(!fileManager.fileExists(atPath: obsoleteLockURL.path))
    #expect(try service.loadWorkspace(at: packageURL).definition == workspace)
    let generationURL = try #require(
      backupService.generationPackageURLs(for: workspace.lineageID).first
    )
    #expect(try service.loadWorkspace(at: generationURL).definition == workspace)
  }

  @MainActor
  @Test func failedCoordinatedCopyRestoresTheExistingWorkspace() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let initialStore = try WorkspaceStore(clean: WorkspaceDefinition(name: "Before"))
    try WorkspacePackageService(fileManager: fileManager).saveWorkspaceStore(
      initialStore,
      to: packageURL
    )

    let store = try WorkspacePackageService(fileManager: fileManager).loadWorkspaceStore(
      at: packageURL
    )
    store.edit { $0.name = "After" }
    store.editPreferences { $0.outputDestination.streamsToYouTube = true }
    let backupService = WorkspaceBackupService(
      fileManager: fileManager,
      rootDirectoryURL: root.appendingPathComponent("Backups")
    )
    var didInjectFailure = false
    let service = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService,
      publishData: { data, url in
        if url.lastPathComponent == WorkspacePackageLayout.preferencesProtobufFileName,
          !didInjectFailure
        {
          didInjectFailure = true
          throw TestWriteError.injectedFailure
        }
        try data.write(to: url, options: [.atomic])
      }
    )

    #expect(throws: TestWriteError.injectedFailure) {
      try service.saveWorkspaceStore(store, to: packageURL)
    }

    #expect(store.isDirty)
    #expect(try service.loadWorkspace(at: packageURL).definition.name == "Before")
    let generationURL = try #require(
      backupService.generationPackageURLs(for: store.definition.lineageID).first
    )
    #expect(try service.loadWorkspace(at: generationURL).definition.name == "After")
    #expect(
      !fileManager.fileExists(
        atPath: generationURL.deletingLastPathComponent()
          .appendingPathComponent("Rollback.ldtxworkspace").path
      ))
  }

  @MainActor
  @Test func invalidBackupGenerationIsDiscardedWithoutPruningValidHistory() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let backupService = WorkspaceBackupService(
      fileManager: fileManager,
      rootDirectoryURL: root.appendingPathComponent("Backups"),
      maximumGenerationCount: 1
    )
    let validService = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService
    )
    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Before"))
    try validService.saveWorkspaceStore(store, to: packageURL)
    let validGenerationURL = try #require(
      backupService.generationPackageURLs(for: store.definition.lineageID).first
    )

    store.edit { $0.name = "After" }
    let invalidService = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService,
      writeData: { data, url in
        if url.lastPathComponent == WorkspacePackageLayout.protobufFileName {
          try Data("invalid protobuf".utf8).write(to: url, options: [.atomic])
        } else {
          try data.write(to: url, options: [.atomic])
        }
      }
    )

    #expect(throws: (any Error).self) {
      try invalidService.saveWorkspaceStore(store, to: packageURL)
    }

    #expect(store.isDirty)
    #expect(try validService.loadWorkspace(at: packageURL).definition.name == "Before")
    #expect(
      try backupService.generationPackageURLs(for: store.definition.lineageID)
        == [validGenerationURL]
    )
  }

  @MainActor
  @Test func backedUpSavePublishesChangesBetweenFilesAndDirectories() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let assetURL = packageURL.appendingPathComponent("Assets/ChangingItem")
    try fileManager.createDirectory(
      at: assetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("file".utf8).write(to: assetURL)

    let backupService = WorkspaceBackupService(
      fileManager: fileManager,
      rootDirectoryURL: root.appendingPathComponent("Backups")
    )
    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "File to directory"))
    let fileToDirectoryService = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService,
      writeData: { data, url in
        if url.lastPathComponent == WorkspacePackageLayout.protobufFileName {
          let generationAssetURL = url.deletingLastPathComponent()
            .appendingPathComponent("Assets/ChangingItem")
          try fileManager.removeItem(at: generationAssetURL)
          try fileManager.createDirectory(at: generationAssetURL, withIntermediateDirectories: true)
          try Data("nested".utf8).write(
            to: generationAssetURL.appendingPathComponent("content.txt")
          )
        }
        try data.write(to: url, options: [.atomic])
      }
    )

    try fileToDirectoryService.saveWorkspaceStore(store, to: packageURL)
    #expect(
      try Data(contentsOf: assetURL.appendingPathComponent("content.txt"))
        == Data("nested".utf8)
    )

    store.edit { $0.name = "Directory to file" }
    let directoryToFileService = WorkspacePackageService(
      fileManager: fileManager,
      backupService: backupService,
      writeData: { data, url in
        if url.lastPathComponent == WorkspacePackageLayout.protobufFileName {
          let generationAssetURL = url.deletingLastPathComponent()
            .appendingPathComponent("Assets/ChangingItem")
          try fileManager.removeItem(at: generationAssetURL)
          try Data("replacement".utf8).write(to: generationAssetURL)
        }
        try data.write(to: url, options: [.atomic])
      }
    )

    try directoryToFileService.saveWorkspaceStore(store, to: packageURL)
    #expect(try Data(contentsOf: assetURL) == Data("replacement".utf8))
  }

  @MainActor
  @Test func loadWorkspaceStoreUsesPackageProtobufAsSavedBytes() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    try service.saveWorkspaceStore(
      try WorkspaceStore(clean: WorkspaceDefinition(name: "Stored")),
      to: packageURL
    )

    let store = try service.loadWorkspaceStore(at: packageURL)

    #expect(store.definition.name == "Stored")
    #expect(!store.isDirty)
  }

  @MainActor
  @Test func saveWorkspaceStoreMarksWrittenProtobufAsClean() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Store"))
    store.editPreferences { preferences in
      preferences.physicalDeviceIDsByInputDeviceID = ["workspace-mic": "audio-1"]
      preferences.selectedProgramName = "Store Program"
    }
    store.edit { workspace in
      workspace.programs = [
        SavedProgramDefinitionRecord(
          name: "Store Program",
          canvasWidth: 1920,
          canvasHeight: 1080,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          composite: CompositeProgramDefinition()
        )
      ]
      workspace.inputDevices = [
        WorkspaceInputDeviceRecord(
          id: "workspace-mic",
          name: "Mic",
          kind: .audio,
        )
      ]
    }
    #expect(store.isDirty)

    try service.saveWorkspaceStore(store, to: packageURL)

    #expect(!store.isDirty)
    let loaded = try service.loadWorkspace(at: packageURL)
    #expect(loaded.definition == store.definition)
    #expect(loaded.preferences == store.preferences)
  }

  @MainActor
  @Test func savingStoreAlsoPreservesTheWorkspaceDefinition() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    let store = try WorkspaceStore(
      clean: WorkspaceDefinition(
        programs: [
          SavedProgramDefinitionRecord(
            name: "Main",
            canvasWidth: 1920,
            canvasHeight: 1080,
            frameRateNumerator: 60,
            frameRateDenominator: 1,
            composite: CompositeProgramDefinition()
          )
        ],
        inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)],
        videoComponents: [
          WorkspaceVideoComponentRecord(
            name: "Camera Component",
            component: .inputCameraDevice(
              InputDeviceComponent(
                inputDeviceID: "Camera",
                destinationX: 120,
                destinationY: 80,
                destinationScale: 0.5
              ))
          )
        ]
      ))
    store.editPreferences {
      $0.selectedProgramName = "Main"
      $0.programPreferences.setVideoLayers(
        [
          VideoLayerPreference(
            componentName: "Camera Component",
            destinationX: 120,
            destinationY: 80,
            destinationScale: 0.5
          )
        ],
        forProgramNamed: "Main"
      )
    }

    try service.saveWorkspaceStore(store, to: packageURL)

    let reloaded = try service.loadWorkspaceStore(at: packageURL)
    let component = try #require(reloaded.definition.videoComponents.first?.component)
    guard case .inputCameraDevice(let payload) = component else {
      Issue.record("Expected an input camera component")
      return
    }
    #expect(payload.destination == InputDeviceDestination())
    #expect(
      reloaded.preferences.programPreferences.videoLayers(forProgramNamed: "Main") == [
        VideoLayerPreference(
          componentName: "Camera Component",
          destinationX: 120,
          destinationY: 80,
          destinationScale: 0.5
        )
      ])
    #expect(reloaded.preferences.selectedProgramName == "Main")
  }

  @MainActor
  @Test func failedStagingWriteLeavesExistingPackageAndStoreUntouched() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }

    let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
    let initialStore = try WorkspaceStore(clean: WorkspaceDefinition(name: "Before"))
    try WorkspacePackageService().saveWorkspaceStore(initialStore, to: packageURL)

    let store = try WorkspacePackageService().loadWorkspaceStore(at: packageURL)
    store.edit { $0.name = "After" }
    let service = WorkspacePackageService(writeData: { data, url in
      if url.lastPathComponent == WorkspacePackageLayout.preferencesProtobufFileName {
        throw TestWriteError.injectedFailure
      }
      try data.write(to: url, options: [.atomic])
    })

    #expect(throws: TestWriteError.injectedFailure) {
      try service.saveWorkspaceStore(store, to: packageURL)
    }
    #expect(store.isDirty)
    #expect(
      try WorkspacePackageService().loadWorkspace(at: packageURL).definition.name == "Before"
    )
  }

  @Test func compileValidatesBothJSONMirrorsBeforeReplacingEitherProtobuf() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }
    let packageURL = root.appendingPathComponent("Compile.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    let initial = WorkspacePersistenceSnapshot(
      definition: WorkspaceDefinition(name: "Before"),
      preferences: WorkspacePreferences(),
      protobufData: try WorkspacePersistenceCodec.encodeWorkspace(
        WorkspaceDefinition(name: "Before"))
    )
    try service.save(initial, to: packageURL)
    let workspacePB = packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName)
    let preferencesPB = packageURL.appendingPathComponent(
      WorkspacePackageLayout.preferencesProtobufFileName)
    let originalWorkspacePB = try Data(contentsOf: workspacePB)
    let originalPreferencesPB = try Data(contentsOf: preferencesPB)

    try WorkspacePersistenceCodec.encodeWorkspaceJSON(WorkspaceDefinition(name: "After"))
      .write(
        to: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName),
        options: .atomic)
    try Data("{}".utf8).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName),
      options: .atomic)

    #expect(throws: WorkspacePersistenceError.unsupportedLegacyFormat(0)) {
      try service.compileJSONMirrors(at: packageURL)
    }
    #expect(try Data(contentsOf: workspacePB) == originalWorkspacePB)
    #expect(try Data(contentsOf: preferencesPB) == originalPreferencesPB)
  }

  @Test func compileAndEmitJSONPreserveTheCanonicalPairContract() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }
    let packageURL = root.appendingPathComponent("Compile.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    let before = WorkspaceDefinition(name: "Before")
    try service.save(
      WorkspacePersistenceSnapshot(
        definition: before,
        preferences: WorkspacePreferences(),
        protobufData: try WorkspacePersistenceCodec.encodeWorkspace(before)
      ),
      to: packageURL)

    let after = WorkspaceDefinition(name: "After")
    try WorkspacePersistenceCodec.encodeWorkspaceJSON(after).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName),
      options: .atomic)
    try service.compileJSONMirrors(at: packageURL)
    #expect(try service.loadWorkspace(at: packageURL).definition.name == "After")
    try service.validatePackage(at: packageURL)

    try Data("stale".utf8).write(
      to: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName),
      options: .atomic)
    try service.emitJSONMirrors(at: packageURL)
    try service.validatePackage(at: packageURL)
  }

  @Test func validationRejectsCanonicalUnknownFieldsMissingFromJSONMirror() throws {
    let fileManager = FileManager.default
    let root = try temporaryDirectory()
    defer { try? fileManager.removeItem(at: root) }
    let packageURL = root.appendingPathComponent("UnknownField.ldtxworkspace")
    let service = WorkspacePackageService(fileManager: fileManager)
    let workspace = WorkspaceDefinition(name: "Unknown Field")
    try service.save(
      WorkspacePersistenceSnapshot(
        definition: workspace,
        preferences: WorkspacePreferences(),
        protobufData: try WorkspacePersistenceCodec.encodeWorkspace(workspace)
      ),
      to: packageURL)

    let workspacePB = packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName)
    var protobufData = try Data(contentsOf: workspacePB)
    protobufData.append(contentsOf: [0xA0, 0x06, 0x01])
    try protobufData.write(to: workspacePB, options: .atomic)
    let workspaceJSON = packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName)
    let originalWorkspaceJSON = try Data(contentsOf: workspaceJSON)

    #expect(
      throws: WorkspacePackageServiceError.jsonMirrorMismatch(
        WorkspacePackageLayout.jsonFileName)
    ) {
      try service.validatePackage(at: packageURL)
    }
    #expect(
      throws: WorkspacePackageServiceError.jsonMirrorMismatch(
        WorkspacePackageLayout.jsonFileName)
    ) {
      try service.emitJSONMirrors(at: packageURL)
    }
    #expect(try Data(contentsOf: workspaceJSON) == originalWorkspaceJSON)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("LDTXWorkspaceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private enum TestWriteError: Error, Equatable {
  case injectedFailure
}
