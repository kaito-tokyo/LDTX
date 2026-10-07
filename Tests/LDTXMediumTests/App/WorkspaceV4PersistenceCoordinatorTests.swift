// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import Security
import Testing

@MainActor
@Suite("Version 4 Workspace persistence coordinator")
struct WorkspaceV4PersistenceCoordinatorIntegrationTestSuite {
  private final class ObservationFlag: @unchecked Sendable {
    var didChange = false
  }

  @Test("loads a package without writing or replacing current edits")
  func loadsWithoutWritingOrMarkingSaved() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let box = WorkspaceBox(cleanWorkspace(displayName: "Unite"))
    let coordinator = makeCoordinator(box)

    try WorkspaceDocumentPackage.write(box.workspace, to: packageURL, createsPackage: true)
    let reloaded = try coordinator.load(at: packageURL)

    #expect(reloaded.definition.displayName == "Unite")
    box.workspace.definition.displayName = "Pending"
    #expect(try coordinator.load(at: packageURL).definition.displayName == "Unite")
    #expect(coordinator.workspace.definition.displayName == "Pending")
  }

  @Test("keeps app-local state keyed by package path and reloads it")
  func keysAndReloadsAppLocalStateByPackagePath() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let original = URL(fileURLWithPath: "/tmp/Original.ldtxworkspace")
    let savedAs = URL(fileURLWithPath: "/tmp/SavedAs.ldtxworkspace")
    appletData.setState(WorkspaceLocalState(selectedProgramInternalID: 7), for: original)
    #expect(appletData.state(for: original).selectedProgramInternalID == 7)
    #expect(appletData.state(for: savedAs).selectedProgramInternalID == nil)

    let reopenedAppletData = WorkspaceAppletData(userDefaults: defaults)
    #expect(reopenedAppletData.state(for: original).selectedProgramInternalID == 7)
    #expect(reopenedAppletData.state(for: savedAs).selectedProgramInternalID == nil)
  }

  @Test("publishes app-local state changes to observers")
  func publishesAppLocalStateChanges() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let workspaceURL = URL(fileURLWithPath: "/tmp/Observable.ldtxworkspace")
    let observationFlag = ObservationFlag()

    withObservationTracking {
      _ = appletData.state(for: workspaceURL).selectedProgramInternalID
    } onChange: {
      observationFlag.didChange = true
    }

    appletData.setState(WorkspaceLocalState(selectedProgramInternalID: 7), for: workspaceURL)

    #expect(observationFlag.didChange)
    #expect(appletData.state(for: workspaceURL).selectedProgramInternalID == 7)
  }

  @Test("persists all app-local fields deterministically")
  func persistsAllAppLocalFields() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let url = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    let state = WorkspaceLocalState(
      selectedProgramInternalID: 42,
      monitorAudioInputDeviceInternalIDs: [5],
      landscapeYouTubeLiveStreamID: "landscape",
      portraitYouTubeLiveStreamID: "portrait")
    appletData.setState(state, for: url)
    let reopened = WorkspaceAppletData(userDefaults: defaults)
    #expect(reopened.state(for: url) == state)
  }

  @Test func deviceAssignmentsPersistIndependentlyOfWorkspaceURLs() throws {
    let suite = "SharedDeviceAssignments.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let first = URL(fileURLWithPath: "/tmp/First.ldtxworkspace")
    let second = URL(fileURLWithPath: "/tmp/Second.ldtxworkspace")
    appletData.setState(.init(selectedProgramInternalID: 7), for: first)
    appletData.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "camera"), for: 3)
    appletData.setPhysicalDeviceID(.coreAudioDevice(uid: "mic"), for: 5)
    appletData.copyState(from: first, to: second)
    let reopened = WorkspaceAppletData(userDefaults: defaults)
    #expect(reopened.physicalDeviceID(for: 3) == .avCaptureDevice(uniqueID: "camera"))
    #expect(reopened.physicalDeviceID(for: 5) == .coreAudioDevice(uid: "mic"))
    #expect(reopened.physicalDeviceID(for: 4) == nil)
    #expect(reopened.state(for: second).selectedProgramInternalID == 7)
    reopened.setPhysicalDeviceID(nil, for: 3)
    #expect(WorkspaceAppletData(userDefaults: defaults).physicalDeviceID(for: 3) == nil)
    #expect(
      WorkspaceAppletData(userDefaults: defaults).physicalDeviceID(for: 5)
        == .coreAudioDevice(uid: "mic"))
    defaults.set(Data([0xff]), forKey: "tokyo.kaito.ldtx.input-device-assignments.v1")
    #expect(
      WorkspaceAppletData(userDefaults: defaults).physicalDeviceIDsByResourceInternalID.isEmpty)
  }

  @Test func discardsOldProtobufStoreAndPersistsNewLocalState() throws {
    let suiteName = "WorkspaceAppletDataPropertyListTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let oldKey = "tokyo.kaito.ldtx.workspace-local-state.v1"
    let newKey = "tokyo.kaito.ldtx.workspace-local-state.v2"
    // Protobuf fixture: one path-keyed state with selected Program ID 42.
    let path = Array("/tmp/Workspace.ldtxworkspace".utf8)
    let entry = [UInt8(0x0a), UInt8(path.count)] + path + [0x12, 0x02, 0x08, 0x2a]
    let oldData = Data([UInt8(0x0a), UInt8(entry.count)] + entry)
    defaults.set(oldData, forKey: oldKey)

    let url = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    #expect(appletData.state(for: url) == WorkspaceLocalState())

    let state = WorkspaceLocalState(
      selectedProgramInternalID: 17,
      monitorAudioInputDeviceInternalIDs: [5],
      landscapeYouTubeLiveStreamID: "landscape",
      portraitYouTubeLiveStreamID: "portrait")
    appletData.setState(state, for: url)

    #expect(defaults.data(forKey: oldKey) == nil)
    #expect(defaults.data(forKey: newKey)?.starts(with: Data("bplist".utf8)) == true)
    #expect(WorkspaceAppletData(userDefaults: defaults).state(for: url) == state)
  }

  @Test("persists stream key configurations through the Keychain interface")
  func persistsStreamKeyConfigurations() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var keychainData: Data?
    let keychain = WorkspaceAppletKeychainClient(
      copyMatching: { _, result in
        guard let keychainData else { return errSecItemNotFound }
        result?.pointee = keychainData as CFTypeRef
        return errSecSuccess
      },
      update: { _, attributes in
        guard keychainData != nil else { return errSecItemNotFound }
        keychainData = (attributes as NSDictionary)[kSecValueData as String] as? Data
        return errSecSuccess
      },
      add: { attributes, _ in
        keychainData = (attributes as NSDictionary)[kSecValueData as String] as? Data
        return keychainData == nil ? errSecParam : errSecSuccess
      })
    let appletData = WorkspaceAppletData(userDefaults: defaults, keychainClient: keychain)
    let configurations = [
      YouTubeRTMPSStreamKeyConfiguration(
        id: "landscape", name: "Landscape", streamURL: "rtmps://a.rtmp.youtube.com/live2",
        streamKey: "example-key")
    ]

    try appletData.saveYouTubeStreamKeyConfigurations(configurations)

    #expect(try appletData.loadYouTubeStreamKeyConfigurations() == configurations)
    #expect(appletData.youtubeStreamKeyConfigurations == configurations)
  }

  @Test("rejects duplicate stream keys before writing to Keychain")
  func rejectsDuplicateStreamKeys() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var addCount = 0
    let keychain = WorkspaceAppletKeychainClient(
      copyMatching: { _, _ in errSecItemNotFound },
      update: { _, _ in errSecItemNotFound },
      add: { _, _ in
        addCount += 1
        return errSecSuccess
      })
    let appletData = WorkspaceAppletData(userDefaults: defaults, keychainClient: keychain)
    let configurations = ["one", "two"].map { id in
      YouTubeRTMPSStreamKeyConfiguration(
        id: id, name: id, streamURL: "rtmps://a.rtmp.youtube.com/live2", streamKey: "same-key")
    }

    #expect(throws: YouTubeStreamKeyConfigurationError.saveFailed) {
      try appletData.saveYouTubeStreamKeyConfigurations(configurations)
    }
    #expect(addCount == 0)
  }

  private final class WorkspaceBox {
    var workspace: WorkspaceV4Bundle
    init(_ workspace: WorkspaceV4Bundle) {
      self.workspace = workspace
    }
    func replace(_ value: WorkspaceV4Bundle) throws {
      try WorkspaceV4IntegrityValidator.validate(value)
      workspace = value
    }
  }

  private func makeCoordinator(_ box: WorkspaceBox, url: URL? = nil)
    -> WorkspaceV4PersistenceCoordinator
  {
    return WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace },
      replaceWorkspace: { try box.replace($0) },
      url: url)
  }

  private func cleanWorkspace(displayName: String) -> WorkspaceV4Bundle {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = displayName
    definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    definition.canvasConfiguration.frameRate = 60
    definition.canvasConfiguration.landscapeVideoBitRate = 6_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 6_000_000
    definition.outputConfiguration.youtubeIngestMode = .landscapeRtmps
    return WorkspaceV4Bundle(definition: definition, preferences: .init())
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
