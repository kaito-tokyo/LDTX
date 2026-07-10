// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import Foundation
import LDTXAppUI
import LDTXAutomation
import LDTXCapture
import LDTXProgram
import LDTXProgramRendering
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTube
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let ldtxAppLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "App"
)

private enum WorkspaceStorageKey {
  static let lastWorkspacePath = "tokyo.kaito.ldtx.LDTX.Workspace.lastWorkspacePath"
}

private enum OutputSessionLifecycleState {
  case idle
  case starting
  case running
  case pausing
  case readyToRestart
  case stopping
}

extension UTType {
  static let ldtxWorkspace = UTType(exportedAs: "tokyo.kaito.ldtx.workspace")
}

struct WorkspaceContainer: View {
  @ObservedObject var oauthClientState: OAuthClientState
  @ObservedObject var authState: YouTubeAuthState
  private let youtubeClientService: YouTubeClientService
  private let workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private let activeProgramRuntime: ActiveProgramRuntime
  @State private var streamStatus = "No broadcast"
  @State private var captureStatus = "Idle"
  @State private var outputCanvas = OutputCanvasModel()
  @State private var outputDestination = OutputDestinationModel()
  @State private var existingBroadcasts: [YouTubeLiveBroadcast] = []
  @State private var compositeProgramDefinition = CompositeProgramDefinition()
  @State private var programInputDevices: [WorkspaceInputDeviceRecord] = []
  @State private var workspaceAudioChannels: [ProgramAudioChannel] = []
  @State private var programArguments = ProgramArguments()
  @State private var inputCameraDeviceMappings: [String: String] = [:]
  @State private var inputAudioDeviceMappings: [String: String] = [:]
  @State private var audioPeakMeter = ProgramAudioPeakMeter()
  @State private var audioMonitor = ProgramAudioMonitor()
  @State private var dashStreamContinuityStore = ProgramDASHStreamContinuityStore()
  @State private var audioMonitorTask: Task<Void, Never>?
  @State private var inputAudioPassthroughChannelKeys: Set<String> = []
  @State private var isLoadingBroadcasts = false
  @State private var isConnectingBroadcast = false
  @State private var youtubeStreamingSession: ProgramDASHStreamingSession?
  @State private var outputSessionLifecycleState: OutputSessionLifecycleState = .idle
  @State private var outputSessionOperationID = UUID()
  @State private var activeCaptureOutputMode: CaptureOutputMode?
  @State private var captureDeviceStore = CaptureDeviceStore(service: DefaultCaptureDeviceService())
  @State private var localOutputStore = LocalOutputStore(
    service: DefaultLocalOutputService(fileManager: .default)
  )
  @State private var logStore = LogStore()
  @State private var programLibrary = ProgramLibrary(
    service: InMemoryProgramLibraryService()
  )
  @State private var programArgumentsLibrary = ProgramArgumentsLibrary(
    service: InMemoryProgramArgumentsLibraryService()
  )
  @State private var selectedSidebarItem: WorkspaceSidebarItem? = .streamSettings
  @State private var selectedProgramDefinitionName: String?
  @State private var workspaceStore = try! WorkspaceStore(clean: WorkspaceDefinition())
  @State private var workspaceURL: URL?
  @State private var didInitializeWorkspace = false
  @State private var isProgramDefinitionDirty = false
  @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
  @State private var programAddErrorMessage: String?
  @State private var isShowingProgramRenamePopover = false
  @State private var proposedProgramName = ""
  @StateObject private var automationState = AppAutomationState()
  private let automationEndpoint = LDTXAppAutomationEndpoint()

  init(
    oauthClientState: OAuthClientState,
    authState: YouTubeAuthState,
    youtubeClientService: YouTubeClientService
  ) {
    self.oauthClientState = oauthClientState
    self.authState = authState
    self.youtubeClientService = youtubeClientService
    let workspaceCaptureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
    activeProgramRuntime = ActiveProgramRuntime(
      captureSessionCoordinator: workspaceCaptureSessionCoordinator
    )
  }

  var body: some View {
    workspaceView
      .modifier(workspaceDocumentLifecycle)
      .modifier(outputSettingsPersistence)
      .modifier(programRuntimeObservation)
      .focusedSceneValue(\.workspaceActions, workspaceActions)
  }

  private var workspaceView: some View {
    LDTXAppUI.WorkspaceView(
      selectedSidebarItem: $selectedSidebarItem,
      selectedProgramDefinitionName: $selectedProgramDefinitionName,
      workspaceInputDevices: programInputDevicesBinding,
      workspaceAudioChannels: $workspaceAudioChannels,
      compositeProgramDefinition: $compositeProgramDefinition,
      programArguments: $programArguments,
      saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
      programAddErrorMessage: $programAddErrorMessage,
      isShowingProgramRenamePopover: $isShowingProgramRenamePopover,
      proposedProgramName: $proposedProgramName,
      outputCanvas: outputCanvas,
      outputDestination: outputDestination,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      activeProgramRuntime: activeProgramRuntime,
      activeProgramSnapshot: activeProgramSnapshot(),
      selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
      programRecords: programLibrary.records,
      activeProgramSelection: activeProgramSelectionBinding,
      inputCameraDeviceMappings: inputCameraDeviceMappings,
      audioPeakMeter: audioPeakMeter,
      inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeysBinding,
      cameras: captureDeviceStore.cameras.map { InputPhysicalDeviceOption(camera: $0) },
      audioDevices: captureDeviceStore.audioDevices.map { InputPhysicalDeviceOption(audioDevice: $0) },
      existingBroadcasts: existingBroadcasts,
      isLoadingBroadcasts: isLoadingBroadcasts,
      isConnectingBroadcast: isConnectingBroadcast,
      isStreamingToYouTube: isStreamingToYouTube,
      isRecording: isRecording,
      localOutputStatus: localOutputStore.status,
      canSelectYouTubeBroadcast: canCreateLiveStream,
      isOutputSessionRunning: isOutputSessionRunning,
      outputSessionControlState: outputSessionControlState,
      canEditInputDevices: canEditInputDevices,
      canEditOutputSettings: canEditOutputSettings,
      isGlobalOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      globalOutputSessionStartAccessibilityLabel: globalOutputSessionStartAccessibilityLabel,
      globalOutputSessionStartHelp: globalOutputSessionStartHelp,
      globalOutputSessionStopHelp: globalOutputSessionStopHelp,
      isWorkspaceSaveToolbarEnabled: isWorkspaceSaveToolbarEnabled,
      updateProgramAudioGains: updateProgramAudioGains(arguments:),
      reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
      refreshCameras: refreshCameras,
      deleteWorkspaceInputDevice: deleteWorkspaceInputDevice(id:),
      saveProgramDefinitionRecord: saveProgramDefinitionRecord(_:),
      programDefinitionDirtyChanged: { isDirty in
        isProgramDefinitionDirty = isDirty
        updateWorkspaceWindowDirtyState()
      },
      stopOutputSession: stopOutputSession,
      startOutputSession: startOutputSession,
      pauseOutputSession: pauseOutputSession,
      addProgramDefinition: addProgramDefinition,
      showProgramRenamePopover: showProgramRenamePopover,
      renameSelectedProgramDefinitionFromPopover: renameSelectedProgramDefinitionFromPopover,
      saveWorkspace: saveWorkspace,
      refreshExistingBroadcasts: refreshExistingBroadcasts,
      manageYouTubeBroadcasts: manageYouTubeBroadcasts,
      chooseLocalOutputDirectory: chooseLocalOutputDirectory
    )
  }

  private func performStartupTasks() {
    restoreOutputSettings()
    loadInitialWorkspace()
    updateWorkspaceWindowDirtyState()
    configureAutomationHandlers()
    if LDTXBrokerAgentRegistration.registerIfNeeded() {
      automationEndpoint.start(state: automationState)
    }
    refreshSavedProgramDefinitions()
    refreshAutomationSelectedProgram()
    refreshCameras()
    restartAudioMonitor()
  }

  private var workspaceDocumentLifecycle: WorkspaceDocumentLifecycle {
    WorkspaceDocumentLifecycle(
      selectedProgramName: selectedProgramDefinitionRecord?.name,
      isWorkspaceDirty: workspaceStore.isDirty,
      performStartupTasks: performStartupTasks,
      refreshAutomationSelectedProgram: refreshAutomationSelectedProgram,
      updateWorkspaceWindowDirtyState: updateWorkspaceWindowDirtyState,
      stopAudioMonitor: stopAudioMonitor,
      openWorkspace: { url in
        openWorkspace(at: url)
      }
    )
  }

  private var outputSettingsPersistence: OutputSettingsPersistence {
    OutputSettingsPersistence(
      outputDestination: outputDestination,
      persistOutputSettings: persistOutputSettings
    )
  }

  private var programRuntimeObservation: ProgramRuntimeObservation {
    ProgramRuntimeObservation(
      programArguments: programArguments,
      compositeProgramDefinition: compositeProgramDefinition,
      workspaceAudioChannels: workspaceAudioChannels,
      outputCanvasState: outputCanvas.state,
      inputAudioDeviceMappings: inputAudioDeviceMappings,
      workspaceInputDevices: programInputDevices,
      updateProgramAudioGains: programArgumentsChanged(_:),
      programDefinitionChanged: programDefinitionChanged,
      outputCanvasChanged: outputCanvasChanged,
      audioDeviceMappingChanged: restartAudioMonitor,
      workspaceInputDevicesChanged: workspaceInputDevicesChanged
    )
  }

  private func stopAudioMonitor() {
    audioMonitorTask?.cancel()
    Task {
      await audioMonitor.stop()
      audioPeakMeter.reset()
    }
  }

  private func programArgumentsChanged(_ arguments: ProgramArguments) {
    persistCurrentProgramArguments(arguments)
    updateProgramAudioGains(arguments: arguments)
  }

  private func programDefinitionChanged() {
    updateProgramAudioGains(arguments: programArguments)
    restartAudioMonitor()
  }

  private func outputCanvasChanged() {
    programDefinitionChanged()
    synchronizeInputDeviceCaptures()
  }

  private func markProgramDefinitionDirty() {
    isProgramDefinitionDirty = true
    updateWorkspaceWindowDirtyState()
  }

  private var workspaceActions: WorkspaceActions {
    WorkspaceActions(
      newWorkspace: newWorkspace,
      openWorkspace: chooseWorkspaceToOpen,
      saveWorkspace: saveWorkspace,
      saveWorkspaceAs: saveWorkspaceAs
    )
  }

  private var activeProgramSelectionBinding: Binding<String?> {
    Binding(
      get: { selectedProgramDefinitionName },
      set: { selectedName in
        selectProgramDefinition(named: selectedName, clearsDetailSelection: false)
      }
    )
  }

  private var inputAudioPassthroughChannelKeysBinding: Binding<Set<String>> {
    Binding(
      get: { inputAudioPassthroughChannelKeys },
      set: { channelKeys in
        inputAudioPassthroughChannelKeys = channelKeys
        restartAudioMonitor()
      }
    )
  }

  private var hasUnsavedWorkspaceChanges: Bool {
    workspaceStore.isDirty || isProgramDefinitionDirty
  }

  private var programInputDevicesBinding: Binding<[WorkspaceInputDeviceRecord]> {
    Binding(
      get: { programInputDevices },
      set: { newValue in
        programInputDevices = newValue
        markProgramDefinitionDirty()
        synchronizeInputDeviceCaptures()
        restartAudioMonitor()
      }
    )
  }

  private func loadInitialWorkspace() {
    guard !didInitializeWorkspace else { return }
    didInitializeWorkspace = true
    if LDTXRuntimeMode.isUITesting {
      loadUITestingWorkspace()
      return
    }
    if restoreLastWorkspace() {
      return
    }
    let hiddenWindow = hideWorkspaceWindowForInitialWorkspaceCreation()
    if createWorkspaceFromSavePanel(clearsDetailSelectionAfterLoad: false) {
      hiddenWindow?.makeKeyAndOrderFront(nil)
    } else {
      NSApplication.shared.terminate(nil)
    }
  }

  private func loadUITestingWorkspace() {
    do {
      let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LDTXUITests", isDirectory: true)
        .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        .appendingPathExtension(WorkspacePackageLayout.pathExtension)
      let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "UITest"))
      try replaceWorkspaceStore(store, url: packageURL, clearsDetailSelection: false)
      appendLog("Loaded UI testing Workspace: \(packageURL.path)")
    } catch {
      appendLog("UI testing Workspace could not be loaded: \(error.localizedDescription)")
    }
  }

  private func newWorkspace() {
    guard confirmDiscardUnsavedWorkspaceIfNeeded() else { return }
    createWorkspaceFromSavePanel()
  }

  private func restoreLastWorkspace() -> Bool {
    guard let path = UserDefaults.standard.string(forKey: WorkspaceStorageKey.lastWorkspacePath),
      !path.isEmpty
    else {
      return false
    }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    do {
      let store = try WorkspacePackageService().loadWorkspaceStore(at: url)
      try replaceWorkspaceStore(store, url: url, clearsDetailSelection: false)
      rememberWorkspaceURL(url)
      appendLog("Restored last Workspace: \(url.path)")
      return true
    } catch {
      UserDefaults.standard.removeObject(forKey: WorkspaceStorageKey.lastWorkspacePath)
      appendLog("Last Workspace could not be restored: \(error.localizedDescription)")
      return false
    }
  }

  private func hideWorkspaceWindowForInitialWorkspaceCreation() -> NSWindow? {
    let window =
      NSApplication.shared.keyWindow
      ?? NSApplication.shared.windows.first { window in
        window.isVisible && !(window is NSPanel)
      }
    window?.orderOut(nil)
    return window
  }

  @discardableResult
  private func createWorkspaceFromSavePanel(
    clearsDetailSelectionAfterLoad: Bool = true
  ) -> Bool {
    let panel = workspaceSavePanel(
      fileName: defaultNewWorkspaceFileName,
      directoryURL: iCloudDocumentsDirectory(),
      message: "Create a new LDTX Workspace.",
      prompt: "Create"
    )
    guard panel.runModal() == .OK, let url = panel.url else { return false }

    do {
      let packageURL = workspacePackageURL(for: url)
      let store = try WorkspaceStore(clean: WorkspaceDefinition())
      store.edit { definition in
        definition.name = packageURL.deletingPathExtension().lastPathComponent
      }
      try WorkspacePackageService().saveWorkspaceStore(store, to: packageURL)
      try replaceWorkspaceStore(
        store,
        url: packageURL,
        clearsDetailSelection: clearsDetailSelectionAfterLoad
      )
      try WorkspacePackageService().saveWorkspaceStore(workspaceStore, to: packageURL)
      rememberWorkspaceURL(packageURL)
      appendLog("Created Workspace: \(packageURL.path)")
      return true
    } catch {
      appendLog("Workspace could not be created: \(error.localizedDescription)")
      return false
    }
  }

  private func chooseWorkspaceToOpen() {
    guard confirmDiscardUnsavedWorkspaceIfNeeded() else { return }

    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.ldtxWorkspace]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Open an LDTX Workspace."
    panel.prompt = "Open"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    openWorkspace(at: url, confirmsUnsavedChanges: false)
  }

  private func openWorkspace(at url: URL, confirmsUnsavedChanges: Bool = true) {
    if confirmsUnsavedChanges {
      guard confirmDiscardUnsavedWorkspaceIfNeeded() else { return }
    }
    do {
      let store = try WorkspacePackageService().loadWorkspaceStore(at: url)
      try replaceWorkspaceStore(store, url: url)
      rememberWorkspaceURL(url)
      appendLog("Opened Workspace: \(url.path)")
    } catch {
      appendLog("Workspace could not be opened: \(error.localizedDescription)")
    }
  }

  private func saveWorkspace() {
    guard let workspaceURL else {
      saveWorkspaceAs()
      return
    }
    saveWorkspace(to: workspaceURL)
  }

  private func saveWorkspaceAs() {
    let panel = workspaceSavePanel(
      fileName: suggestedWorkspaceFileName,
      directoryURL: workspaceURL?.deletingLastPathComponent() ?? iCloudDocumentsDirectory(),
      message: "Save the current LDTX Workspace.",
      prompt: "Save"
    )
    guard panel.runModal() == .OK, let url = panel.url else { return }
    saveWorkspace(to: workspacePackageURL(for: url))
  }

  @discardableResult
  private func saveWorkspace(to url: URL) -> Bool {
    do {
      saveCurrentProgramDefinitionIfNeeded()
      syncWorkspaceFromCurrentProgramLibrary()
      try WorkspacePackageService().saveWorkspaceStore(workspaceStore, to: url)
      workspaceURL = url
      rememberWorkspaceURL(url)
      updateWorkspaceWindowDirtyState()
      appendLog("Saved Workspace: \(url.path)")
      return true
    } catch {
      appendLog("Workspace could not be saved: \(error.localizedDescription)")
      return false
    }
  }

  private func workspaceSavePanel(
    fileName: String,
    directoryURL: URL?,
    message: String,
    prompt: String
  ) -> NSSavePanel {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.ldtxWorkspace]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = fileName
    panel.directoryURL = directoryURL
    panel.message = message
    panel.prompt = prompt
    return panel
  }

  private func iCloudDocumentsDirectory() -> URL? {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "tokyo.kaito.ldtx.LDTX"
    let containerIdentifier = "iCloud.\(bundleIdentifier)"
    let fileManager = FileManager.default
    guard
      let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
        ?? fileManager.url(forUbiquityContainerIdentifier: nil)
    else {
      return nil
    }

    let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
    try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    return documentsURL
  }

  private func rememberWorkspaceURL(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: WorkspaceStorageKey.lastWorkspacePath)
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
  }

  private var suggestedWorkspaceFileName: String {
    let name =
      workspaceURL?.lastPathComponent
      ?? "\(workspaceStore.definition.name).\(WorkspacePackageLayout.pathExtension)"
    return name.hasSuffix(".\(WorkspacePackageLayout.pathExtension)")
      ? name
      : "\(name).\(WorkspacePackageLayout.pathExtension)"
  }

  private var defaultNewWorkspaceFileName: String {
    "Default.\(WorkspacePackageLayout.pathExtension)"
  }

  private func workspacePackageURL(for url: URL) -> URL {
    if url.pathExtension == WorkspacePackageLayout.pathExtension {
      return url
    }
    return url.appendingPathExtension(WorkspacePackageLayout.pathExtension)
  }

  private func syncWorkspaceFromCurrentProgramLibrary() {
    let workspaceName =
      workspaceURL?.deletingPathExtension().lastPathComponent
      ?? workspaceStore.definition.name
    workspaceStore.edit { definition in
      definition.name = workspaceName
      definition.programs = programLibrary.records
      definition.programArguments = programArgumentsLibrary.records
      definition.audioChannels = workspaceAudioChannels
    }
  }

  private func replaceWorkspaceStore(
    _ store: WorkspaceStore,
    url: URL?,
    clearsDetailSelection: Bool = true
  ) throws {
    workspaceStore = store
    workspaceURL = url
    workspaceAudioChannels =
      store.definition.audioChannels.isEmpty
      ? store.definition.programs.first(where: { !$0.composite.audioChannels.isEmpty })?.composite.audioChannels ?? []
      : store.definition.audioChannels
    isProgramDefinitionDirty = false
    updateWorkspaceWindowDirtyState()
    let selectedName = store.definition.programs.first?.name
    try programLibrary.replaceRecords(store.definition.programs, selectedName: selectedName)
    try programArgumentsLibrary.replaceRecords(store.definition.programArguments)
    let selectedRecord = try programLibrary.ensureDefaultProgram()
    syncWorkspaceFromCurrentProgramLibrary()
    selectProgramDefinition(named: selectedRecord.name, clearsDetailSelection: clearsDetailSelection)
    synchronizeInputDeviceCaptures()
  }

  private func updateWorkspaceWindowDirtyState() {
    for window in NSApplication.shared.windows where window.isVisible && !(window is NSPanel) {
      window.isDocumentEdited = hasUnsavedWorkspaceChanges
    }
  }

  private func confirmDiscardUnsavedWorkspaceIfNeeded() -> Bool {
    guard hasUnsavedWorkspaceChanges else { return true }

    let alert = NSAlert()
    alert.messageText = "Do you want to save changes to this Workspace?"
    alert.informativeText = "Your changes will be lost if you don't save them."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Don't Save")
    alert.alertStyle = .warning

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      saveWorkspace()
      return !hasUnsavedWorkspaceChanges
    case .alertThirdButtonReturn:
      return true
    default:
      return false
    }
  }

  private func saveCurrentProgramDefinitionIfNeeded() {
    guard isProgramDefinitionDirty,
      saveProgramDefinitionCommand?.isEnabled == true
    else {
      return
    }
    saveProgramDefinitionCommand?.perform()
  }

  private var isWorkspaceSaveToolbarEnabled: Bool {
    hasUnsavedWorkspaceChanges || workspaceURL == nil
  }

  private var isOutputSessionRunning: Bool {
    outputSessionLifecycleState == .running
  }

  private var outputSessionControlState: OutputSessionControlState {
    switch outputSessionLifecycleState {
    case .idle:
      .idle
    case .starting:
      .starting
    case .running:
      .running
    case .pausing:
      .pausing
    case .readyToRestart:
      .readyToRestart
    case .stopping:
      .stopping
    }
  }

  private var canEditInputDevices: Bool {
    outputSessionLifecycleState == .idle || outputSessionLifecycleState == .readyToRestart
  }

  private var canEditOutputSettings: Bool {
    outputSessionLifecycleState == .idle
  }

  private var canStartOutputSession: Bool {
    outputSessionLifecycleState == .idle || outputSessionLifecycleState == .readyToRestart
  }

  private var isStreamingToYouTube: Bool {
    isOutputSessionRunning && activeCaptureOutputMode?.streamsToYouTube == true
  }

  private var isRecording: Bool {
    isOutputSessionRunning && activeCaptureOutputMode?.recordsLocally == true
  }

  private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord? {
    savedProgramDefinition(named: selectedProgramDefinitionName)
  }

  private var selectedExistingBroadcast: YouTubeLiveBroadcast? {
    guard let selectedExistingBroadcastID = outputDestination.selectedExistingBroadcastID else {
      return nil
    }
    return existingBroadcasts.first { $0.id == selectedExistingBroadcastID }
  }

  private var preferredExistingBroadcast: YouTubeLiveBroadcast? {
    selectedExistingBroadcast ?? recommendedExistingBroadcast
  }

  private var recommendedExistingBroadcast: YouTubeLiveBroadcast? {
    let activeBroadcasts = existingBroadcasts
      .filter { broadcast in
        broadcast.snippet?.actualEndTime == nil
          && (broadcast.snippet?.actualStartTime != nil || broadcast.status?.lifeCycleStatus == "live")
      }
      .sorted { left, right in
        broadcastActivityDate(left) > broadcastActivityDate(right)
      }
    if let activeBroadcast = activeBroadcasts.first {
      return activeBroadcast
    }

    let upcomingBroadcasts = existingBroadcasts
      .filter { $0.snippet?.actualStartTime == nil }
      .sorted { left, right in
        broadcastScheduleDate(left) < broadcastScheduleDate(right)
      }
    if let upcomingBroadcast = upcomingBroadcasts.first {
      return upcomingBroadcast
    }

    return existingBroadcasts.first
  }

  private var isGlobalOutputSessionStartEnabled: Bool {
    if isLoadingBroadcasts || isConnectingBroadcast {
      return false
    }
    if !canStartOutputSession {
      return false
    }
    guard canStartProgramAudioMix else {
      return false
    }

    switch outputDestination.selectedCaptureOutputMode {
    case .youtube, .youtubeAndRecord:
      return true
    case .record:
      return true
    }
  }

  private var canCreateLiveStream: Bool {
    if isLoadingBroadcasts || isConnectingBroadcast {
      return false
    }
    if isOutputSessionRunning {
      return false
    }
    return outputDestination.selectedCaptureOutputMode.streamsToYouTube
  }

  private var globalOutputSessionStartAccessibilityLabel: String {
    switch outputDestination.selectedCaptureOutputMode {
    case .youtube:
      return "Start Stream"
    case .record:
      return "Start Recording"
    case .youtubeAndRecord:
      return "Start Stream & Record"
    }
  }

  private var globalOutputSessionStopHelp: String {
    if isStreamingToYouTube && isRecording {
      return "Stop streaming and local recording."
    }
    if isStreamingToYouTube {
      return "Stop streaming to YouTube."
    }
    if isRecording {
      return "Stop local recording."
    }
    return "Stop output."
  }

  private var globalOutputSessionStartHelp: String {
    if !canStartProgramAudioMix {
      return "Configure and map a Workspace audio channel before starting output."
    }
    if outputDestination.selectedCaptureOutputMode.streamsToYouTube,
      preferredExistingBroadcast == nil
    {
      return "Create or schedule a YouTube broadcast in Manage before connecting."
    }

    switch outputDestination.selectedCaptureOutputMode {
    case .youtube:
      return "Connect to the active YouTube broadcast."
    case .record:
      return "Start local recording."
    case .youtubeAndRecord:
      return "Connect to YouTube and start local recording."
    }
  }

  private var effectiveWorkspaceAudioChannels: [ProgramAudioChannel] {
    programInputDevices.resolvedWorkspaceAudioChannels(from: workspaceAudioChannels)
  }

  @discardableResult
  private func synchronizeWorkspaceAudioChannelsWithInputDevices() -> Bool {
    let resolvedAudioChannels = programInputDevices.resolvedWorkspaceAudioChannels(
      from: workspaceAudioChannels
    )
    guard resolvedAudioChannels != workspaceAudioChannels else {
      return false
    }
    workspaceAudioChannels = resolvedAudioChannels
    return true
  }

  private var canStartProgramAudioMix: Bool {
    let audioChannels = effectiveWorkspaceAudioChannels
    guard !audioChannels.isEmpty else {
      return false
    }

    let mappings = mappedInputAudioDeviceIDs(
      for: .composite,
      composite: compositeProgramDefinition,
      audioChannels: audioChannels,
      workspaceInputDevices: programInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    for channel in audioChannels
    where channel.component.definition.usesInputAudioDevice {
      let key = audioChannels.inputAudioDeviceMappingKey(for: channel)
      guard mappings[key]?.isEmpty == false else {
        return false
      }
    }
    return true
  }

  private func savedProgramDefinition(named name: String?) -> SavedProgramDefinitionRecord? {
    guard let name else {
      return nil
    }
    return programLibrary.records.first { $0.name == name }
  }

  private func refreshSavedProgramDefinitions() {
    reloadSavedProgramDefinitions()
    reloadProgramArguments()
  }

  private func reloadSavedProgramDefinitions() {
    do {
      try programLibrary.reload()
      let selectedRecord = try programLibrary.ensureDefaultProgram()
      syncWorkspaceFromCurrentProgramLibrary()
      selectProgramDefinition(named: selectedRecord.name, clearsDetailSelection: false)
    } catch {
      programLibrary.resetAfterRestoreFailure()
      programArgumentsLibrary.resetAfterRestoreFailure()
      appendLog("Stored program definitions could not be restored and were reset.")
      addProgramDefinition()
    }
  }

  private func reloadProgramArguments() {
    do {
      try programArgumentsLibrary.reload()
      if let selectedName = selectedProgramDefinitionName {
        programArguments =
          programArgumentsLibrary.arguments(named: selectedName) ?? ProgramArguments()
      }
    } catch {
      programArgumentsLibrary.resetAfterRestoreFailure()
      programArguments = ProgramArguments()
      appendLog("Stored program arguments could not be restored and were reset.")
    }
  }

  private func selectProgramDefinition(named name: String?, clearsDetailSelection: Bool = true) {
    if clearsDetailSelection {
      clearDetailSelection()
    }
    let selectedName = name ?? programLibrary.records.first?.name
    selectedProgramDefinitionName = selectedName
    if let record = savedProgramDefinition(named: selectedName) {
      compositeProgramDefinition = record.composite
      programInputDevices = record.inputDevices
      synchronizeWorkspaceAudioChannelsWithInputDevices()
      outputCanvas.sync(from: record)
      programArguments = programArgumentsLibrary.arguments(named: record.name) ?? ProgramArguments()
      isProgramDefinitionDirty = false
      updateWorkspaceWindowDirtyState()
    } else {
      programInputDevices = []
      synchronizeWorkspaceAudioChannelsWithInputDevices()
    }
    restartAudioMonitor()
    synchronizeInputDeviceCaptures()
    refreshAutomationSelectedProgram()
  }

  private func clearDetailSelection() {
    selectedSidebarItem = .streamSettings
  }

  private func refreshAutomationSelectedProgram() {
    automationState.updateSelectedProgram(
      name: selectedProgramDefinitionRecord?.name ?? "",
      isScratchPad: false
    )
  }

  private func activeProgramDefinitionRecord() -> SavedProgramDefinitionRecord? {
    let name =
      selectedProgramDefinitionRecord?.name
      ?? selectedProgramDefinitionName
      ?? programLibrary.records.first?.name
    guard let name else {
      return nil
    }
    return SavedProgramDefinitionRecord(
      name: name,
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      frameRateNumerator: max(outputCanvas.programDefinitionFrameRate, 1),
      frameRateDenominator: 1,
      composite: outputCanvas.applying(to: compositeProgramDefinition),
      inputDevices: programInputDevices
    )
  }

  private func configureAutomationHandlers() {
    automationState.updateHandlers(
      AppAutomationHandlers(
        terminate: {
          appendLog("Automation requested app termination.")
          DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
          }
          return AppAutomationCommandResult(ok: true, message: "Termination requested.")
        },
        activeProgramDefinition: {
          activeProgramDefinitionRecord()
        },
        selectProgram: { name, isScratchPad in
          if isScratchPad {
            return AppAutomationCommandResult(
              ok: false, message: "Only saved Programs can be selected.")
          }

          guard savedProgramDefinition(named: name) != nil else {
            return AppAutomationCommandResult(ok: false, message: "Program not found: \(name)")
          }
          selectProgramDefinition(named: name)
          return AppAutomationCommandResult(ok: true, message: "Selected Program: \(name)")
        },
        selectInputDevice: { workspaceInputDeviceID, physicalDeviceID in
          guard canEditInputDevices else {
            return AppAutomationCommandResult(
              ok: false, message: "Pause output before changing Input Devices.")
          }
          return selectInputDevice(
            workspaceInputDeviceID: workspaceInputDeviceID,
            physicalDeviceID: physicalDeviceID
          )
        },
        startOutput: {
          guard canStartOutputSession else {
            return AppAutomationCommandResult(ok: true, message: "Output is already running.")
          }
          guard canStartProgramAudioMix else {
            return AppAutomationCommandResult(
              ok: false,
              message: "Configure a Workspace Audio Channel before starting output."
            )
          }

          startOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Output start requested.")
        },
        stopOutput: {
          guard outputSessionLifecycleState != .idle else {
            return AppAutomationCommandResult(ok: true, message: "Output is not running.")
          }

          stopOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Output stop requested.")
        },
        startRecording: {
          guard canStartOutputSession else {
            if isRecording {
              return AppAutomationCommandResult(ok: true, message: "Recording is already running.")
            }
            return AppAutomationCommandResult(
              ok: false, message: "Another output session is already running.")
          }

          if outputSessionLifecycleState == .idle {
            outputDestination.selectedCaptureOutputMode = .record
          } else if outputDestination.selectedCaptureOutputMode != .record {
            return AppAutomationCommandResult(
              ok: false, message: "Stop output before changing Output Settings.")
          }
          startOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Recording start requested.")
        },
        stopRecording: {
          guard outputSessionLifecycleState != .idle,
            outputDestination.selectedCaptureOutputMode.recordsLocally
          else {
            return AppAutomationCommandResult(ok: true, message: "Recording is not running.")
          }

          stopOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Recording stop requested.")
        },
        splitRecording: {
          if let failure = RecordingSplitAutomationSupport.validationFailure(
            isOutputSessionRunning: isOutputSessionRunning,
            activeCaptureOutputMode: activeCaptureOutputMode
          ) {
            return failure
          }
          guard youtubeStreamingSession?.requestRecordingSplit() == true else {
            return AppAutomationCommandResult(
              ok: false, message: "Recording split could not be queued.")
          }
          appendLog("Recording split requested.")
          return AppAutomationCommandResult(ok: true, message: "Recording split requested.")
        },
        inputDevices: {
          programInputDevices
        },
        outputSettings: {
          outputSettingsProto()
        },
        setOutputSettings: { settings in
          applyOutputSettings(settings)
        }
      ))
  }

  private func outputSettingsProto() -> Ldtx_Automation_V1_OutputSettings {
    var settings = Ldtx_Automation_V1_OutputSettings()
    settings.captureOutputMode = outputDestination.selectedCaptureOutputMode.protoValue

    var youtube = Ldtx_Automation_V1_YouTubeOutputSettings()
    youtube.title = outputDestination.streamTitle
    youtube.description_p = outputDestination.streamDescription
    youtube.resolution = derivedYouTubeStreamResolution.protoValue
    youtube.frameRate = derivedYouTubeStreamFrameRate.protoValue
    youtube.usesTemporaryStream = true
    youtube.existingBroadcastID = outputDestination.selectedExistingBroadcastID ?? ""
    settings.youtube = youtube

    var recording = Ldtx_Automation_V1_RecordingOutputSettings()
    recording.baseDirectoryPath = localOutputStore.baseDirectory.path
    settings.recording = recording

    return settings
  }

  private func applyOutputSettings(
    _ settings: Ldtx_Automation_V1_OutputSettings
  ) -> AppAutomationCommandResult {
    guard canEditOutputSettings else {
      return AppAutomationCommandResult(
        ok: false,
        message: "Output settings cannot be changed while output is running."
      )
    }

    do {
      if settings.hasCaptureOutputMode {
        outputDestination.selectedCaptureOutputMode = try CaptureOutputMode(
          protoValue: settings.captureOutputMode)
      }

      if settings.hasYoutube {
        try applyYouTubeOutputSettings(settings.youtube)
      }

      if settings.hasRecording {
        try applyRecordingOutputSettings(settings.recording)
      }

      persistOutputSettings()
      appendLog("Automation updated Output Settings.")
      return AppAutomationCommandResult(ok: true, message: "Output Settings updated.")
    } catch let error as OutputSettingsAutomationError {
      return AppAutomationCommandResult(ok: false, message: error.message)
    } catch {
      return AppAutomationCommandResult(ok: false, message: error.localizedDescription)
    }
  }

  private func applyYouTubeOutputSettings(
    _ settings: Ldtx_Automation_V1_YouTubeOutputSettings
  ) throws {
    if settings.hasTitle {
      outputDestination.streamTitle = settings.title
    }
    if settings.hasDescription_p {
      outputDestination.streamDescription = settings.description_p
    }
    outputDestination.usesTemporaryStream = true
    if settings.hasExistingBroadcastID {
      let trimmed = settings.existingBroadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
      outputDestination.selectedExistingBroadcastID = trimmed.isEmpty ? nil : trimmed
    }
  }

  private func applyRecordingOutputSettings(
    _ settings: Ldtx_Automation_V1_RecordingOutputSettings
  ) throws {
    guard settings.hasBaseDirectoryPath else { return }
    let trimmed = settings.baseDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw OutputSettingsAutomationError("Recording baseDirectoryPath must not be empty.")
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw OutputSettingsAutomationError(
        "Recording baseDirectoryPath is not a directory: \(trimmed)")
    }
    localOutputStore.selectBaseDirectory(URL(fileURLWithPath: trimmed, isDirectory: true))
  }

  private func restoreOutputSettings() {
    let defaults = UserDefaults.standard
    if let mode = CaptureOutputMode(
      rawValue: defaults.string(forKey: OutputSettingsStorageKey.captureOutputMode) ?? "")
    {
      outputDestination.selectedCaptureOutputMode = mode
    }
    outputDestination.streamTitle =
      defaults.string(forKey: OutputSettingsStorageKey.streamTitle) ?? outputDestination.streamTitle
    outputDestination.streamDescription =
      defaults.string(forKey: OutputSettingsStorageKey.streamDescription)
      ?? outputDestination.streamDescription
    outputDestination.usesTemporaryStream = true
    let broadcastID = defaults.string(forKey: OutputSettingsStorageKey.existingBroadcastID) ?? ""
    outputDestination.selectedExistingBroadcastID = broadcastID.isEmpty ? nil : broadcastID
    outputDestination.prefersColorPreview = defaults.bool(
      forKey: OutputSettingsStorageKey.prefersColorPreview)

    if let baseDirectoryPath = defaults.string(
      forKey: OutputSettingsStorageKey.localOutputBaseDirectoryPath),
      !baseDirectoryPath.isEmpty
    {
      localOutputStore.selectBaseDirectory(
        URL(fileURLWithPath: baseDirectoryPath, isDirectory: true))
    }
  }

  private func persistOutputSettings() {
    let defaults = UserDefaults.standard
    defaults.set(
      outputDestination.selectedCaptureOutputMode.rawValue,
      forKey: OutputSettingsStorageKey.captureOutputMode)
    defaults.set(
      outputDestination.selectedExistingBroadcastID ?? "",
      forKey: OutputSettingsStorageKey.existingBroadcastID)
    defaults.set(outputDestination.streamTitle, forKey: OutputSettingsStorageKey.streamTitle)
    defaults.set(
      outputDestination.streamDescription,
      forKey: OutputSettingsStorageKey.streamDescription)
    outputDestination.usesTemporaryStream = true
    defaults.set(true, forKey: OutputSettingsStorageKey.usesTemporaryStream)
    defaults.set(
      outputDestination.prefersColorPreview,
      forKey: OutputSettingsStorageKey.prefersColorPreview)
    defaults.set(
      localOutputStore.baseDirectory.path,
      forKey: OutputSettingsStorageKey.localOutputBaseDirectoryPath)
  }

  private func saveProgramDefinitionRecord(_ record: SavedProgramDefinitionRecord) -> Bool {
    do {
      try programLibrary.save(record)
      try programArgumentsLibrary.save(programArguments, named: record.name)
      syncWorkspaceFromCurrentProgramLibrary()
      return true
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
      return false
    }
  }

  private func addProgramDefinition() {
    do {
      let record = try programLibrary.appendEmpty()
      syncWorkspaceFromCurrentProgramLibrary()
      selectProgramDefinition(named: record.name)
    } catch let error as ProgramLibraryError {
      programAddErrorMessage = error.localizedDescription
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  private func showProgramRenamePopover() {
    guard let selectedName = selectedProgramDefinitionName else {
      return
    }
    proposedProgramName = selectedName
    isShowingProgramRenamePopover = true
  }

  private func renameSelectedProgramDefinitionFromPopover() {
    guard let selectedName = selectedProgramDefinitionName else {
      return
    }
    guard renameProgramDefinition(oldName: selectedName, to: proposedProgramName) != nil else {
      return
    }
    isShowingProgramRenamePopover = false
  }

  private func renameProgramDefinition(oldName: String, to proposedName: String) -> String? {
    do {
      guard let renamed = try programLibrary.rename(oldName: oldName, to: proposedName) else {
        return nil
      }
      if renamed.name != oldName {
        try programArgumentsLibrary.rename(oldName: oldName, to: renamed.name)
      }
      if selectedProgramDefinitionName == oldName {
        selectedProgramDefinitionName = renamed.name
      }
      syncWorkspaceFromCurrentProgramLibrary()
      refreshAutomationSelectedProgram()
      return renamed.name
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
      return nil
    }
  }

  private func deleteProgramDefinition(named name: String) {
    let deletedSelectedProgram = selectedProgramDefinitionName == name
    do {
      try programLibrary.delete(named: name)
      try programArgumentsLibrary.delete(named: name)
      syncWorkspaceFromCurrentProgramLibrary()
      guard deletedSelectedProgram else {
        return
      }
      if let replacement = programLibrary.records.first {
        selectProgramDefinition(named: replacement.name)
      } else {
        let replacement = try programLibrary.ensureDefaultProgram()
        syncWorkspaceFromCurrentProgramLibrary()
        selectProgramDefinition(named: replacement.name)
      }
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  private func deleteWorkspaceInputDevice(id: String) {
    guard canEditInputDevices else { return }
    programInputDevices.removeAll { $0.id == id }
    markProgramDefinitionDirty()
    synchronizeInputDeviceCaptures()
    if selectedSidebarItem == .inputDevice(id) {
      if let replacementID = programInputDevices.first?.id {
        selectedSidebarItem = .inputDevice(replacementID)
      } else {
        clearDetailSelection()
      }
    }

    compositeProgramDefinition = compositeClearingInputDeviceReference(
      id, in: compositeProgramDefinition)
    workspaceAudioChannels = workspaceAudioChannels.map { channel in
      guard case .inputAudioDevice(var payload) = channel.component,
        payload.inputDeviceID == id
      else {
        return channel
      }
      payload.inputDeviceID = nil
      return ProgramAudioChannel(id: channel.id, component: .inputAudioDevice(payload))
    }
    restartAudioMonitor()
  }

  private func compositeClearingInputDeviceReference(
    _ inputDeviceID: String,
    in composite: CompositeProgramDefinition
  ) -> CompositeProgramDefinition {
    var updated = composite
    for stepIndex in updated.steps.indices {
      guard case .inputCameraDevice(var payload) = updated.steps[stepIndex].component,
        payload.inputDeviceID == inputDeviceID
      else {
        continue
      }
      payload.inputDeviceID = nil
      updated.steps[stepIndex].component = .inputCameraDevice(payload)
    }
    return updated
  }

  private func persistCurrentProgramArguments(_ arguments: ProgramArguments) {
    guard let selectedName = selectedProgramDefinitionName else {
      return
    }
    do {
      try programArgumentsLibrary.save(arguments, named: selectedName)
      syncWorkspaceFromCurrentProgramLibrary()
    } catch {
      appendLog("Program arguments could not be saved: \(error.localizedDescription)")
    }
  }

  private func updateProgramAudioGains(arguments: ProgramArguments) {
    audioMonitor.updateGains(
      audioChannels: effectiveWorkspaceAudioChannels,
      arguments: arguments
    )
  }

  private func restartAudioMonitor() {
    audioMonitorTask?.cancel()
    let audioChannels = effectiveWorkspaceAudioChannels
    let inputAudioDeviceMappings = inputAudioDeviceMappings
    let workspaceInputDevices = programInputDevices
    let resolvedInputAudioDeviceMappings = mappedInputAudioDeviceIDs(
      for: .composite,
      composite: compositeProgramDefinition,
      audioChannels: audioChannels,
      workspaceInputDevices: workspaceInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    let programArguments = programArguments
    let inputPassthroughChannelKeys = inputAudioPassthroughChannelKeys
    let audioMonitor = audioMonitor
    let audioPeakMeter = audioPeakMeter
    audioMonitorTask = Task {
      do {
        try await audioMonitor.restart(
          audioChannels: audioChannels,
          inputAudioDeviceMappings: resolvedInputAudioDeviceMappings,
          programArguments: programArguments,
          inputPassthroughChannelKeys: inputPassthroughChannelKeys,
          peakMeter: audioPeakMeter
        )
      } catch is CancellationError {
      } catch {
        audioPeakMeter.reset()
        appendLog("Audio monitor failed: \(errorDescription(error))")
      }
    }
  }

  private func workspaceInputDevicesChanged() {
    let didChangeAudioChannels = synchronizeWorkspaceAudioChannelsWithInputDevices()
    synchronizeInputDeviceCaptures()
    if !didChangeAudioChannels {
      restartAudioMonitor()
    }
  }

  private func refreshExistingBroadcasts() {
    Task {
      isLoadingBroadcasts = true
      defer { isLoadingBroadcasts = false }

      do {
        let broadcasts = try await loadExistingBroadcasts()
        existingBroadcasts = broadcasts
        appendLog("Loaded \(broadcasts.count) active/upcoming YouTube broadcast(s).")
      } catch {
        appendLog("Broadcast list failed: \(errorDescription(error))")
        logError("Broadcast list failed", error: error)
      }
    }
  }

  private func loadExistingBroadcasts() async throws -> [YouTubeLiveBroadcast] {
    let accessToken = try await authState.validAccessToken(
      configuration: oauthClientState.configuration
    )
    let broadcasts = try await youtubeClientService.refreshExistingBroadcasts(
      accessToken: accessToken
    )
    if authState.channelID == nil {
      authState.refreshChannelID(configuration: oauthClientState.configuration)
    }
    return broadcasts
  }

  private func manageYouTubeBroadcasts() {
    if let url = youtubeLiveManagementURL(channelID: knownYouTubeChannelID) {
      appendLog("Opening YouTube Live management: \(url.absoluteString)")
      NSWorkspace.shared.open(url)
      return
    }

    Task {
      do {
        let accessToken = try await authState.validAccessToken(
          configuration: oauthClientState.configuration
        )
        let channelID = try await youtubeClientService.authenticatedChannelID(
          accessToken: accessToken)
        authState.refreshChannelID(configuration: oauthClientState.configuration)

        guard let url = youtubeLiveManagementURL(channelID: channelID) else {
          appendLog("YouTube channel ID is unavailable.")
          return
        }
        appendLog("Opening YouTube Live management: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
      } catch {
        appendLog("YouTube channel ID lookup failed: \(errorDescription(error))")
        logError("YouTube channel ID lookup failed", error: error)
      }
    }
  }

  private func connectYouTubeBroadcast(
    _ broadcast: YouTubeLiveBroadcast,
    operationID: UUID
  ) {
    guard let broadcastID = broadcast.id else {
      appendLog("YouTube broadcast is missing an ID.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    let outputMode = outputDestination.selectedCaptureOutputMode
    guard outputMode.streamsToYouTube else {
      appendLog("Select YouTube or YouTube+Record before connecting a broadcast.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard !effectiveWorkspaceAudioChannels.isEmpty else {
      appendLog("Configure a Workspace Audio Channel before starting output.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard outputSessionLifecycleState == .starting,
      outputSessionOperationID == operationID
    else {
      return
    }

    Task {
      isConnectingBroadcast = true
      defer { isConnectingBroadcast = false }

      do {
        let snapshot = activeProgramSnapshot()
        try await requestRequiredCaptureAccess(snapshot: snapshot)
        let accessToken = try await authState.validAccessToken(
          configuration: oauthClientState.configuration
        )
        guard outputSessionOperationID == operationID,
          outputSessionLifecycleState == .starting
        else {
          return
        }
        outputDestination.selectedExistingBroadcastID = broadcastID
        outputDestination.usesTemporaryStream = true

        let result = try await youtubeClientService.createDASHStream(
          accessToken: accessToken,
          request: YouTubeClientService.DASHStreamRequest(
            title: outputDestination.streamTitle,
            description: outputDestination.streamDescription,
            resolution: derivedYouTubeStreamResolution,
            frameRate: derivedYouTubeStreamFrameRate,
            usesTemporaryStream: true,
            existingBroadcast: broadcast
          )
        )
        if authState.channelID == nil {
          authState.refreshChannelID(configuration: oauthClientState.configuration)
        }
        guard outputSessionOperationID == operationID,
          outputSessionLifecycleState == .starting
        else {
          do {
            try await youtubeClientService.rollbackDASHStreamCreation(
              accessToken: accessToken,
              result: result
            )
          } catch {
            logError("Cancelled YouTube broadcast cleanup failed", error: error)
            appendLog("Cancelled YouTube broadcast cleanup failed: \(errorDescription(error))")
          }
          return
        }
        guard let dashEndpoint = result.dashEndpoint else {
          appendLog("YouTube LiveStream did not include a DASH endpoint.")
          markOutputSessionReadyToRestart(operationID: operationID)
          return
        }

        let session = ProgramDASHStreamingSession(
          activeProgramRuntime: activeProgramRuntime,
          continuityStore: dashStreamContinuityStore
        )
        youtubeStreamingSession = session
        if outputMode.recordsLocally {
          localOutputStore.beginAccess()
        }
        let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
          for: snapshot.definition,
          composite: snapshot.composite,
          audioChannels: snapshot.audioChannels,
          workspaceInputDevices: programInputDevices,
          inputAudioDeviceMappings: inputAudioDeviceMappings
        )
        try await session.start(
          snapshot: snapshot,
          endpoint: dashEndpoint,
          recordingBaseDirectory: outputMode.recordsLocally ? localOutputStore.baseDirectory : nil,
          programArguments: programArguments,
          audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
          audioRenderer: audioMonitor,
          eventHandler: { message in
            appendLog(message)
          },
          failureHandler: { error in
            guard outputSessionOperationID == operationID else { return }
            streamStatus = "DASH upload failed"
            let description = errorDescription(error)
            let nsError = error as NSError
            ldtxAppLogger.error(
              "DASH upload failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
            )
            appendLog("DASH upload failed: \(description)")
            if outputMode.recordsLocally {
              localOutputStore.endAccess()
            }
            activeCaptureOutputMode = nil
            youtubeStreamingSession = nil
            outputSessionLifecycleState = .readyToRestart
          }
        )

        guard outputSessionOperationID == operationID,
          outputSessionLifecycleState == .starting
        else {
          session.stop()
          return
        }
        outputSessionLifecycleState = .running
        activeCaptureOutputMode = outputMode
        streamStatus = "Streaming to \(broadcast.snippet?.title ?? broadcastID)"
        captureStatus = outputMode.recordsLocally ? "Recording" : captureStatus
        appendLog(
          result.reusedBoundStream
            ? "Connected YouTube broadcast \(broadcastID) using existing bound DASH LiveStream \(result.stream.id ?? "(missing stream id)")."
            : "Connected YouTube broadcast \(broadcastID) to temporary DASH LiveStream \(result.stream.id ?? "(missing stream id)")."
        )
      } catch {
        guard outputSessionOperationID == operationID else { return }
        youtubeStreamingSession?.stop()
        if outputMode.recordsLocally {
          localOutputStore.endAccess()
        }
        activeCaptureOutputMode = nil
        youtubeStreamingSession = nil
        outputSessionLifecycleState = .readyToRestart
        streamStatus = "Connect failed"
        let description = errorDescription(error)
        logError("YouTube broadcast connect failed", error: error)
        appendLog("YouTube broadcast connect failed: \(description)")
      }
    }
  }

  private func stopOutputSession() {
    if outputSessionLifecycleState == .stopping {
      youtubeStreamingSession?.stop()
      return
    }
    guard outputSessionLifecycleState != .idle else {
      return
    }

    let operationID = UUID()
    outputSessionOperationID = operationID
    outputSessionLifecycleState = .stopping
    let session = youtubeStreamingSession
    let outputMode = activeCaptureOutputMode ?? outputDestination.selectedCaptureOutputMode
    session?.stop()
    outputDestination.selectedExistingBroadcastID = nil
    outputDestination.usesTemporaryStream = true

    Task {
      await session?.stopAndWait()
      guard outputSessionOperationID == operationID else { return }
      if outputMode.recordsLocally {
        localOutputStore.endAccess()
      }
      youtubeStreamingSession = nil
      activeCaptureOutputMode = nil
      streamStatus = "Stopped"
      captureStatus = "Idle"
      outputSessionLifecycleState = .idle
      appendLog("Output stopped.")
    }
  }

  private func startOutputSession() {
    guard canStartOutputSession else { return }
    let operationID = UUID()
    outputSessionOperationID = operationID
    outputSessionLifecycleState = .starting
    switch outputDestination.selectedCaptureOutputMode {
    case .youtube, .youtubeAndRecord:
      startYouTubeOutput(operationID: operationID)
    case .record:
      startRecording(operationID: operationID)
    }
  }

  private func markOutputSessionReadyToRestart(operationID: UUID) {
    guard outputSessionOperationID == operationID,
      outputSessionLifecycleState == .starting
    else {
      return
    }
    outputSessionLifecycleState = .readyToRestart
  }

  private func pauseOutputSession() {
    guard outputSessionLifecycleState == .running,
      let session = youtubeStreamingSession
    else {
      return
    }

    let operationID = UUID()
    outputSessionOperationID = operationID
    outputSessionLifecycleState = .pausing
    let outputMode = activeCaptureOutputMode
    session.stop()

    Task {
      await session.stopAndWait()
      guard outputSessionOperationID == operationID,
        outputSessionLifecycleState == .pausing
      else {
        return
      }
      if outputMode?.recordsLocally == true {
        localOutputStore.endAccess()
      }
      youtubeStreamingSession = nil
      activeCaptureOutputMode = nil
      streamStatus = "Paused"
      captureStatus = "Paused"
      outputSessionLifecycleState = .readyToRestart
      appendLog("Output paused. Press Start to begin a new session with the current Output Settings.")
    }
  }

  private func startYouTubeOutput(operationID: UUID) {
    if let broadcast = preferredExistingBroadcast {
      connectYouTubeBroadcast(broadcast, operationID: operationID)
      return
    }

    Task {
      isLoadingBroadcasts = true
      defer { isLoadingBroadcasts = false }

      do {
        let broadcasts = try await loadExistingBroadcasts()
        existingBroadcasts = broadcasts
        appendLog("Loaded \(broadcasts.count) active/upcoming YouTube broadcast(s).")

        guard let broadcast = preferredExistingBroadcast else {
          appendLog("Create or schedule a YouTube broadcast in Manage before connecting.")
          if outputSessionOperationID == operationID {
            outputSessionLifecycleState = .readyToRestart
          }
          return
        }
        connectYouTubeBroadcast(broadcast, operationID: operationID)
      } catch {
        if outputSessionOperationID == operationID {
          outputSessionLifecycleState = .readyToRestart
        }
        appendLog("Broadcast list failed: \(errorDescription(error))")
        logError("Broadcast list failed", error: error)
      }
    }
  }

  private func broadcastActivityDate(_ broadcast: YouTubeLiveBroadcast) -> Date {
    broadcastDate(from: broadcast.snippet?.actualStartTime)
      ?? broadcastDate(from: broadcast.snippet?.publishedAt)
      ?? .distantPast
  }

  private func broadcastScheduleDate(_ broadcast: YouTubeLiveBroadcast) -> Date {
    broadcastDate(from: broadcast.snippet?.scheduledStartTime)
      ?? broadcastDate(from: broadcast.snippet?.publishedAt)
      ?? .distantFuture
  }

  private func broadcastDate(from value: String?) -> Date? {
    guard let value else {
      return nil
    }
    return ISO8601DateFormatter().date(from: value)
  }

  private var knownYouTubeChannelID: String? {
    if let channelID = normalizedChannelID(authState.channelID) {
      return channelID
    }
    if let channelID = normalizedChannelID(
      existingBroadcasts
        .first { $0.id == outputDestination.selectedExistingBroadcastID }?
        .snippet?
        .channelId
    ) {
      return channelID
    }
    return
      existingBroadcasts
      .compactMap { normalizedChannelID($0.snippet?.channelId) }
      .first
  }

  private func youtubeLiveManagementURL(channelID: String?) -> URL? {
    guard let channelID = normalizedChannelID(channelID) else {
      return nil
    }
    return URL(string: "https://studio.youtube.com/channel/\(channelID)/livestreaming")
  }

  private func normalizedChannelID(_ channelID: String?) -> String? {
    guard let trimmed = channelID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private func startRecording(operationID: UUID) {
    guard outputDestination.selectedCaptureOutputMode == .record else {
      appendLog("Select Record before starting local recording.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard outputSessionLifecycleState == .starting,
      outputSessionOperationID == operationID
    else {
      return
    }
    guard !effectiveWorkspaceAudioChannels.isEmpty else {
      appendLog("Configure a Workspace Audio Channel before starting output.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }

    Task {
      do {
        let snapshot = activeProgramSnapshot()
        try await requestRequiredCaptureAccess(snapshot: snapshot)
        guard outputSessionOperationID == operationID,
          outputSessionLifecycleState == .starting
        else {
          return
        }
        let session = ProgramDASHStreamingSession(
          activeProgramRuntime: activeProgramRuntime,
          continuityStore: dashStreamContinuityStore
        )
        youtubeStreamingSession = session
        localOutputStore.beginAccess()
        let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
          for: snapshot.definition,
          composite: snapshot.composite,
          audioChannels: snapshot.audioChannels,
          workspaceInputDevices: programInputDevices,
          inputAudioDeviceMappings: inputAudioDeviceMappings
        )
        try await session.start(
          snapshot: snapshot,
          endpoint: nil,
          recordingBaseDirectory: localOutputStore.baseDirectory,
          programArguments: programArguments,
          audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
          audioRenderer: audioMonitor,
          eventHandler: { message in
            appendLog(message)
          },
          failureHandler: { error in
            guard outputSessionOperationID == operationID else { return }
            captureStatus = "Record failed"
            let description = errorDescription(error)
            let nsError = error as NSError
            ldtxAppLogger.error(
              "Recording failed while running errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
            )
            appendLog("Recording failed: \(description)")
            localOutputStore.endAccess()
            activeCaptureOutputMode = nil
            youtubeStreamingSession = nil
            outputSessionLifecycleState = .readyToRestart
          }
        )

        guard outputSessionOperationID == operationID,
          outputSessionLifecycleState == .starting
        else {
          session.stop()
          return
        }
        outputSessionLifecycleState = .running
        activeCaptureOutputMode = .record
        captureStatus = "Recording"
        appendLog("Recording started.")
      } catch {
        guard outputSessionOperationID == operationID else { return }
        youtubeStreamingSession?.stop()
        localOutputStore.endAccess()
        activeCaptureOutputMode = nil
        youtubeStreamingSession = nil
        outputSessionLifecycleState = .readyToRestart
        captureStatus = "Record failed"
        let description = errorDescription(error)
        let nsError = error as NSError
        ldtxAppLogger.error(
          "Recording failed while starting errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
        )
        appendLog("Recording failed: \(description)")
      }
    }
  }

  private func activeProgramSnapshot() -> ProgramPreviewSnapshot {
    let size = (width: outputCanvas.canvasSize.width, height: outputCanvas.canvasSize.height)
    let definition = ProgramDefinition.composite
    let composite = outputCanvas.applying(to: compositeProgramDefinition)
    let audioChannels = effectiveWorkspaceAudioChannels
    return ProgramPreviewSnapshot(
      definition: definition,
      composite: composite,
      audioChannels: audioChannels,
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      outputWidth: size.width,
      outputHeight: size.height,
      frameRate: max(outputCanvas.programDefinitionFrameRate, 1),
      timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
      programVideoPTSInputKey: programVideoPTSInputKey(
        for: definition,
        composite: composite
      ),
      programAudioDriverKey: programAudioDriverKey(
        for: definition,
        composite: composite,
        audioChannels: audioChannels
      ),
      cameraIDsByInputKey: mappedInputCameraDeviceIDs(
        for: definition,
        composite: composite,
        workspaceInputDevices: programInputDevices,
        inputCameraDeviceMappings: inputCameraDeviceMappings
      ),
      cameraInputColorOverrides: inputCameraColorRangeOverrides(
        for: definition,
        composite: composite,
        workspaceInputDevices: programInputDevices
      ),
      backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
        for: definition,
        composite: composite,
        workspaceInputDevices: programInputDevices
      )
    )
  }

  private var derivedYouTubeStreamResolution: YouTubeLiveStreamResolution {
    switch outputCanvas.canvasSize.height {
    case 0..<360:
      return .p240
    case 360..<480:
      return .p360
    case 480..<720:
      return .p480
    case 720..<1_080:
      return .p720
    case 1_080..<1_440:
      return .p1080
    case 1_440..<2_160:
      return .p1440
    default:
      return .p2160
    }
  }

  private var derivedYouTubeStreamFrameRate: YouTubeLiveStreamFrameRate {
    max(outputCanvas.programDefinitionFrameRate, 1) >= 60 ? .fps60 : .fps30
  }

  private func requestRequiredCaptureAccess(snapshot: ProgramPreviewSnapshot) async throws {
    if snapshot.definition.usesInputCameraDevice(composite: snapshot.composite),
      await requestCaptureAccess(for: .video) == false
    {
      ldtxAppLogger.error("Camera access preflight failed before starting output.")
      throw CameraCaptureServiceError.cameraAccessDenied
    }

    if snapshot.audioChannels.contains(where: {
      $0.component.definition.usesInputAudioDevice
    }),
      await requestCaptureAccess(for: .audio) == false
    {
      ldtxAppLogger.error("Microphone access preflight failed before starting output.")
      throw CameraCaptureServiceError.microphoneAccessDenied
    }
  }

  private func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
          continuation.resume(returning: granted)
        }
      }
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func refreshCameras() {
    let result = captureDeviceStore.reload()
    captureStatus = result.cameras.isEmpty ? "No cameras" : "\(result.cameras.count) camera(s)"
    appendLog(
      "Capture device list refreshed: \(result.cameras.count) camera(s), \(result.audioDevices.count) audio device(s)."
    )
    appendCaptureDeviceDetails(cameras: result.cameras, audioDevices: result.audioDevices)
    if let device = result.restoredSelectedAudioDevice {
      appendLog("Stored capture audio selected: \(device.name).")
    } else if result.didSelectFallbackForUnavailableStoredAudio {
      appendLog("Stored capture audio device is unavailable; selected fallback audio.")
    } else if let preferredAudioDevice = result.preferredAudioDevice {
      appendLog("Preferred safe capture audio selected: \(preferredAudioDevice.name).")
    }
    Task {
      let failedRestartCameraIDs = await workspaceCaptureSessionCoordinator.restartAllCaptureSessions()
      logWorkspaceCaptureSessionFailures(
        failedRestartCameraIDs,
        prefix: "Workspace capture session restart failed for camera(s)"
      )
      await synchronizeInputDeviceCapturesAsync()
    }
  }

  private func synchronizeInputDeviceCaptures() {
    Task {
      await synchronizeInputDeviceCapturesAsync()
    }
  }

  private func synchronizeInputDeviceCapturesAsync() async {
    let failedCameraIDs = await workspaceCaptureSessionCoordinator
      .synchronizeInputDeviceCaptures(
        inputDevices: programInputDevices,
        availableCameraIDs: availableWorkspaceInputDeviceCameraIDs(),
        canvasWidth: outputCanvas.canvasSize.width,
        canvasHeight: outputCanvas.canvasSize.height,
        frameRate: max(outputCanvas.programDefinitionFrameRate, 1)
      )
    logWorkspaceCaptureSessionFailures(
      failedCameraIDs,
      prefix: "Input device capture could not start for camera(s)"
    )
  }

  private func availableWorkspaceInputDeviceCameraIDs() -> Set<String> {
    Set(captureDeviceStore.cameras.map(\.id))
  }

  private func selectInputDevice(
    workspaceInputDeviceID: String,
    physicalDeviceID: String?
  ) -> AppAutomationCommandResult {
    guard canEditInputDevices else {
      return AppAutomationCommandResult(
        ok: false,
        message: "Pause output before changing Input Devices."
      )
    }
    guard let index = programInputDevices.firstIndex(where: {
      $0.id == workspaceInputDeviceID
    }) else {
      return AppAutomationCommandResult(
        ok: false,
        message: "Program Input Device not found: \(workspaceInputDeviceID)"
      )
    }

    let inputDevice = programInputDevices[index]
    if let physicalDeviceID {
      let isAvailable: Bool
      switch inputDevice.kind {
      case .video:
        isAvailable = captureDeviceStore.containsCamera(id: physicalDeviceID)
      case .audio:
        isAvailable = captureDeviceStore.containsAudioDevice(id: physicalDeviceID)
      case .unspecified:
        isAvailable = false
      }

      guard isAvailable else {
        return AppAutomationCommandResult(
          ok: false,
          message: "Physical device is not available for \(inputDevice.kind.rawValue) input: \(physicalDeviceID)"
        )
      }
    }

    var updatedInputDevices = programInputDevices
    var updatedInputDevice = inputDevice
    updatedInputDevice.physicalDeviceID = physicalDeviceID
    updatedInputDevices[index] = updatedInputDevice
    programInputDevices = updatedInputDevices
    markProgramDefinitionDirty()
    synchronizeInputDeviceCaptures()
    restartAudioMonitor()

    if let physicalDeviceID {
      appendLog(
        "Automation selected physical device \(CaptureDeviceStore.redactedDeviceID(physicalDeviceID)) for program input \(inputDevice.name)."
      )
      return AppAutomationCommandResult(
        ok: true,
        message: "Selected physical device for program input: \(inputDevice.name)"
      )
    }

    appendLog("Automation cleared physical device selection for program input \(inputDevice.name).")
    return AppAutomationCommandResult(
      ok: true,
      message: "Cleared physical device selection for program input: \(inputDevice.name)"
    )
  }

  private func logWorkspaceCaptureSessionFailures(
    _ failedCameraIDs: Set<String>,
    prefix: String
  ) {
    guard !failedCameraIDs.isEmpty else {
      return
    }
    let failedDevices = failedCameraIDs
      .sorted()
      .map(CaptureDeviceStore.redactedDeviceID(_:))
      .joined(separator: ", ")
    appendLog("\(prefix): \(failedDevices)")
  }

  private func chooseLocalOutputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = localOutputStore.baseDirectory
    panel.message = "Choose a folder for local DASH and MP4 output."
    panel.prompt = "Use Folder"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    localOutputStore.selectBaseDirectory(url)
    persistOutputSettings()
    appendLog("Local output folder selected: \(url.path)")
  }

  private func appendCaptureDeviceDetails(
    cameras: [CameraCaptureSource],
    audioDevices: [AudioCaptureSource]
  ) {
    for camera in cameras {
      appendLog(
        "Camera device: name=\(camera.name), type=\(camera.deviceType), modelID=\(camera.modelID), id=\(CaptureDeviceStore.redactedDeviceID(camera.id)), external=\(camera.isExternal), format=\(camera.formatSummary)"
      )
    }
    for device in audioDevices {
      appendLog(
        "Audio device: name=\(device.name), type=\(device.deviceType), modelID=\(device.modelID), id=\(CaptureDeviceStore.redactedDeviceID(device.id)), external=\(device.isExternal), format=\(device.formatSummary)"
      )
    }
  }

  private func appendLog(_ message: String) {
    logStore.append(message)
  }

  private func errorDescription(_ error: Error) -> String {
    if let captureError = error as? CameraCaptureServiceError {
      switch captureError {
      case .microphoneAccessDenied:
        return
          "\(captureError.localizedDescription) Allow Microphone access for LDTX in System Settings > Privacy & Security > Microphone, then restart the app."
      case .cameraAccessDenied:
        return
          "\(captureError.localizedDescription) Allow Camera access for LDTX in System Settings > Privacy & Security > Camera, then restart the app."
      default:
        return captureError.localizedDescription
      }
    }
    if let youtubeError = error as? YouTubeLiveAPIError,
      let diagnostics = youtubeError.sanitizedDiagnosticSummary
    {
      return "\(youtubeError.localizedDescription) \(diagnostics)"
    }
    return error.localizedDescription
  }

  private func logError(_ prefix: String, error: Error) {
    let nsError = error as NSError
    if let youtubeError = error as? YouTubeLiveAPIError,
      let diagnostics = youtubeError.sanitizedDiagnosticSummary
    {
      ldtxAppLogger.error(
        "\(prefix, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) \(diagnostics, privacy: .public)"
      )
      return
    }

    ldtxAppLogger.error(
      "\(prefix, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
    )
  }
}

private struct WorkspaceActions {
  var newWorkspace: () -> Void
  var openWorkspace: () -> Void
  var saveWorkspace: () -> Void
  var saveWorkspaceAs: () -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
  typealias Value = WorkspaceActions
}

extension FocusedValues {
  fileprivate var workspaceActions: WorkspaceActions? {
    get { self[WorkspaceActionsKey.self] }
    set { self[WorkspaceActionsKey.self] = newValue }
  }
}

struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceActions) private var workspaceActions

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Workspace") {
        workspaceActions?.newWorkspace()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(workspaceActions == nil)

      Button("Open Workspace...") {
        workspaceActions?.openWorkspace()
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(workspaceActions == nil)
    }

    CommandGroup(replacing: .saveItem) {
      Button("Save") {
        workspaceActions?.saveWorkspace()
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(workspaceActions == nil)

      Button("Save As...") {
        workspaceActions?.saveWorkspaceAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(workspaceActions == nil)
    }
  }
}

private struct OutputSettingsAutomationError: Error {
  var message: String

  init(_ message: String) {
    self.message = message
  }
}

extension CaptureOutputMode {
  fileprivate var protoValue: Ldtx_Automation_V1_CaptureOutputMode {
    switch self {
    case .youtube:
      .youtube
    case .record:
      .record
    case .youtubeAndRecord:
      .youtubeAndRecord
    }
  }

  fileprivate init(protoValue: Ldtx_Automation_V1_CaptureOutputMode) throws {
    switch protoValue {
    case .youtube:
      self = .youtube
    case .record:
      self = .record
    case .youtubeAndRecord:
      self = .youtubeAndRecord
    case .unspecified, .UNRECOGNIZED:
      throw OutputSettingsAutomationError(
        "captureOutputMode must be youtube, record, or youtubeAndRecord.")
    }
  }
}

extension YouTubeLiveStreamResolution {
  fileprivate var protoValue: Ldtx_Automation_V1_YouTubeLiveStreamResolution {
    switch self {
    case .p240:
      .p240
    case .p360:
      .p360
    case .p480:
      .p480
    case .p720:
      .p720
    case .p1080:
      .p1080
    case .p1440:
      .p1440
    case .p2160:
      .p2160
    }
  }

  fileprivate init(protoValue: Ldtx_Automation_V1_YouTubeLiveStreamResolution) throws {
    switch protoValue {
    case .p240:
      self = .p240
    case .p360:
      self = .p360
    case .p480:
      self = .p480
    case .p720:
      self = .p720
    case .p1080:
      self = .p1080
    case .p1440:
      self = .p1440
    case .p2160:
      self = .p2160
    case .unspecified, .UNRECOGNIZED:
      throw OutputSettingsAutomationError(
        "youtube.resolution must be p240, p360, p480, p720, p1080, p1440, or p2160.")
    }
  }
}

extension YouTubeLiveStreamFrameRate {
  fileprivate var protoValue: Ldtx_Automation_V1_YouTubeLiveStreamFrameRate {
    switch self {
    case .fps30:
      .fps30
    case .fps60:
      .fps60
    }
  }

  fileprivate init(protoValue: Ldtx_Automation_V1_YouTubeLiveStreamFrameRate) throws {
    switch protoValue {
    case .fps30:
      self = .fps30
    case .fps60:
      self = .fps60
    case .unspecified, .UNRECOGNIZED:
      throw OutputSettingsAutomationError("youtube.frameRate must be fps30 or fps60.")
    }
  }
}

private struct WorkspaceDocumentLifecycle: ViewModifier {
  var selectedProgramName: String?
  var isWorkspaceDirty: Bool
  var performStartupTasks: () -> Void
  var refreshAutomationSelectedProgram: () -> Void
  var updateWorkspaceWindowDirtyState: () -> Void
  var stopAudioMonitor: () -> Void
  var openWorkspace: (URL) -> Void

  func body(content: Content) -> some View {
    content
      .task {
        performStartupTasks()
      }
      .onChange(of: selectedProgramName) { _, _ in
        refreshAutomationSelectedProgram()
      }
      .onChange(of: isWorkspaceDirty) { _, _ in
        updateWorkspaceWindowDirtyState()
      }
      .onDisappear {
        stopAudioMonitor()
      }
      .onOpenURL { url in
        guard url.isFileURL,
          url.pathExtension == WorkspacePackageLayout.pathExtension
        else {
          return
        }
        openWorkspace(url)
      }
  }
}

private struct OutputSettingsPersistence: ViewModifier {
  var outputDestination: OutputDestinationModel
  var persistOutputSettings: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: outputDestination.selectedExistingBroadcastID) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.selectedCaptureOutputMode) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.streamTitle) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.streamDescription) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.usesTemporaryStream) { _, newValue in
        guard !newValue else { return }
        outputDestination.usesTemporaryStream = true
        persistOutputSettings()
      }
      .onChange(of: outputDestination.prefersColorPreview) { _, _ in
        persistOutputSettings()
      }
  }
}

private struct ProgramRuntimeObservation: ViewModifier {
  var programArguments: ProgramArguments
  var compositeProgramDefinition: CompositeProgramDefinition
  var workspaceAudioChannels: [ProgramAudioChannel]
  var outputCanvasState: OutputCanvasModel.State
  var inputAudioDeviceMappings: [String: String]
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var updateProgramAudioGains: (ProgramArguments) -> Void
  var programDefinitionChanged: () -> Void
  var outputCanvasChanged: () -> Void
  var audioDeviceMappingChanged: () -> Void
  var workspaceInputDevicesChanged: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: programArguments) { _, arguments in
        updateProgramAudioGains(arguments)
      }
      .onChange(of: compositeProgramDefinition) { _, _ in
        programDefinitionChanged()
      }
      .onChange(of: workspaceAudioChannels) { _, _ in
        programDefinitionChanged()
      }
      .onChange(of: outputCanvasState) { _, _ in
        outputCanvasChanged()
      }
      .onChange(of: inputAudioDeviceMappings) { _, _ in
        audioDeviceMappingChanged()
      }
      .onChange(of: workspaceInputDevices) { _, _ in
        workspaceInputDevicesChanged()
      }
  }
}

private extension InputPhysicalDeviceOption {
  init(camera: CameraCaptureSource) {
    self.init(id: camera.id, name: camera.name, isExternal: camera.isExternal)
  }

  init(audioDevice: AudioCaptureSource) {
    self.init(id: audioDevice.id, name: audioDevice.name, isExternal: audioDevice.isExternal)
  }
}
