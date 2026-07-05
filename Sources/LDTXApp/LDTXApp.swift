// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import Foundation
import LDTXAutomation
import LDTXCapture
import LDTXProgram
import LDTXWorkspace
import LDTXYouTube
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let ldtxAppLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "App"
)

let scratchPadProgramDefinitionName = "New Program"

private enum WorkspaceStorageKey {
    static let lastWorkspacePath = "tokyo.kaito.ldtx.LDTX.Workspace.lastWorkspacePath"
}

extension UTType {
    static let ldtxWorkspace = UTType(exportedAs: "tokyo.kaito.ldtx.workspace")
}

@main
struct LDTXApp: App {
    @StateObject private var oauthClientState: OAuthClientState
    @StateObject private var authState: YouTubeAuthState
    private let youtubeClientService: YouTubeClientService
    private let programCameraInputSource = ProgramCameraInputSource()
    @State private var streamStatus = "No broadcast"
    @State private var captureStatus = "Idle"
    @State private var streamTitle = "LDTX"
    @State private var streamDescription = ""
    @State private var usesTemporaryStream = true
    @State private var scratchPadProgramDefinitionRecord = SavedProgramDefinitionRecord(
        name: scratchPadProgramDefinitionName,
        canvasWidth: 1920,
        canvasHeight: 1080,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: CompositeProgramDefinition()
    )
    @State private var scratchPadProgramArguments = ProgramArguments()
    @State private var existingBroadcasts: [YouTubeLiveBroadcast] = []
    @State private var compositeProgramDefinition = CompositeProgramDefinition()
    @State private var programArguments = ProgramArguments()
    @State private var inputCameraDeviceMappings: [String: String] = [:]
    @State private var inputAudioDeviceMappings: [String: String] = [:]
    @State private var audioPeakMeter = ProgramAudioPeakMeter()
    @State private var audioMonitor = ProgramAudioMonitor()
    @State private var audioMonitorTask: Task<Void, Never>?
    @State private var isLoadingBroadcasts = false
    @State private var isConnectingBroadcast = false
    @State private var youtubeStreamingSession: ProgramDASHStreamingSession?
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
    @State private var mainWindowState = MainWindowState.initialValue
    @State private var workspaceStore = try! WorkspaceStore(clean: WorkspaceDefinition())
    @State private var workspaceURL: URL?
    @State private var didInitializeWorkspace = false
    @State private var isProgramDefinitionDirty = false
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @State private var isShowingOutputSettings = false
    @StateObject private var automationState = AppAutomationState()
    private let automationEndpoint = LDTXAppAutomationEndpoint()

    init() {
        let youtubeClientService = YouTubeClientService(
            authorizationStore: YouTubeAuthorizationStore(),
            oauthClientStore: OAuthClientConfigurationStore()
        )
        self.youtubeClientService = youtubeClientService
        _oauthClientState = StateObject(
            wrappedValue: OAuthClientState(youtubeClientService: youtubeClientService)
        )
        _authState = StateObject(
            wrappedValue: YouTubeAuthState(youtubeClientService: youtubeClientService)
        )
    }

    var body: some Scene {
        Window("LDTX", id: "main") {
            NavigationSplitView {
                MainSidebarPane(
                    mainWindowState: $mainWindowState,
                    programLibrary: $programLibrary,
                    selectProgramDefinition: { name in
                        selectProgramDefinition(named: name)
                    },
                    renameProgramDefinition: { oldName, newName in
                        renameProgramDefinition(oldName: oldName, to: newName)
                    },
                    deleteProgramDefinition: { name in
                        deleteProgramDefinition(named: name)
                    }
                )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            } content: {
                MainContentPane(
                    mainWindowState: $mainWindowState,
                    programCameraInputSource: programCameraInputSource,
                    selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                    compositeProgramDefinition: compositeProgramDefinition,
                    programArguments: $programArguments,
                    inputCameraDeviceMappings: inputCameraDeviceMappings,
                    audioPeakMeter: audioPeakMeter,
                    updateProgramAudioGains: updateProgramAudioGains(arguments:)
                )
                    .navigationSplitViewColumnWidth(min: 420, ideal: 640)
            } detail: {
                MainDetailPane(
                    mainWindowState: $mainWindowState,
                    compositeProgramDefinition: $compositeProgramDefinition,
                    inputCameraDeviceMappings: $inputCameraDeviceMappings,
                    inputAudioDeviceMappings: $inputAudioDeviceMappings,
                    captureDeviceStore: captureDeviceStore,
                    programCameraInputSource: programCameraInputSource,
                    selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                    savedProgramDefinitions: programLibrary.records,
                    reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
                    refreshCameras: refreshCameras,
                    saveProgramDefinitionRecord: saveProgramDefinitionRecord(_:),
                    programDefinitionDirtyChanged: { isDirty in
                        isProgramDefinitionDirty = isDirty
                        updateWorkspaceWindowDirtyState()
                    },
                    saveProgramDefinitionCommand: $saveProgramDefinitionCommand
                )
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
            }
            .navigationTitle(workspaceWindowTitle)
            .toolbar {
                outputSessionToolbarItem
                saveProgramToolbarItem
            }
            .sheet(isPresented: $isShowingOutputSettings) {
                OutputSettingsSheet(
                    oauthClientState: oauthClientState,
                    authState: authState,
                    streamStatus: streamStatus,
                    captureStatus: captureStatus,
                    mainWindowState: $mainWindowState,
                    streamTitle: $streamTitle,
                    streamDescription: $streamDescription,
                    usesTemporaryStream: $usesTemporaryStream,
                    existingBroadcasts: existingBroadcasts,
                    isLoadingBroadcasts: isLoadingBroadcasts,
                    isConnectingBroadcast: isConnectingBroadcast,
                    isStreamingToYouTube: isStreamingToYouTube,
                    isRecording: isRecording,
                    localOutputStore: localOutputStore,
                    refreshExistingBroadcasts: refreshExistingBroadcasts,
                    manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                    chooseLocalOutputDirectory: chooseLocalOutputDirectory
                )
            }
            .task {
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
            .onChange(of: selectedProgramDefinitionRecord?.name) { _, _ in
                refreshAutomationSelectedProgram()
            }
            .onChange(of: workspaceStore.isDirty) { _, _ in
                updateWorkspaceWindowDirtyState()
            }
            .onChange(of: mainWindowState) { _, _ in
                persistOutputSettings()
            }
            .onChange(of: streamTitle) { _, _ in
                persistOutputSettings()
            }
            .onChange(of: streamDescription) { _, _ in
                persistOutputSettings()
            }
            .onChange(of: usesTemporaryStream) { _, _ in
                persistOutputSettings()
            }
            .onChange(of: programArguments) { _, arguments in
                persistCurrentProgramArguments(arguments)
                updateProgramAudioGains(arguments: arguments)
            }
            .onChange(of: compositeProgramDefinition) { _, _ in
                updateProgramAudioGains(arguments: programArguments)
                restartAudioMonitor()
            }
            .onChange(of: inputAudioDeviceMappings) { _, _ in
                restartAudioMonitor()
            }
            .onDisappear {
                audioMonitorTask?.cancel()
                Task {
                    await audioMonitor.stop()
                    audioPeakMeter.reset()
                }
            }
            .onOpenURL { url in
                guard url.isFileURL,
                      url.pathExtension == WorkspacePackageLayout.pathExtension else {
                    return
                }
                openWorkspace(at: url)
            }
            .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    newWorkspace()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Workspace...") {
                    chooseWorkspaceToOpen()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    saveWorkspace()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As...") {
                    saveWorkspaceAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        Settings {
            YouTubeAccountSettingsView(
                oauthClientState: oauthClientState,
                authState: authState
            )
        }
    }

    private var outputSessionToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                stopOutputSession()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!isOutputSessionRunning)
            .help(globalOutputSessionStopHelp)
            .accessibilityLabel("Stop Output")
            .accessibilityIdentifier("toolbarStopOutputSessionButton")

            Button {
                startOutputSession()
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(!isGlobalOutputSessionStartEnabled)
            .help(globalOutputSessionStartHelp)
            .accessibilityLabel(globalOutputSessionStartAccessibilityLabel)
            .accessibilityIdentifier("toolbarStartOutputSessionButton")

            if isLoadingBroadcasts || isConnectingBroadcast {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                isShowingOutputSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Output Settings")
            .accessibilityLabel("Output Settings")
            .accessibilityIdentifier("toolbarOutputSettingsButton")
        }
    }

    private var workspaceWindowTitle: String {
        workspaceURL?.deletingPathExtension().lastPathComponent
            ?? workspaceStore.definition.name
    }

    private var hasUnsavedWorkspaceChanges: Bool {
        workspaceStore.isDirty || isProgramDefinitionDirty
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
        let hiddenWindow = hideMainWindowForInitialWorkspaceCreation()
        if createWorkspaceFromSavePanel() {
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
            try replaceWorkspaceStore(store, url: packageURL)
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
              !path.isEmpty else {
            return false
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let store = try WorkspacePackageService().loadWorkspaceStore(at: url)
            try replaceWorkspaceStore(store, url: url)
            rememberWorkspaceURL(url)
            appendLog("Restored last Workspace: \(url.path)")
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: WorkspaceStorageKey.lastWorkspacePath)
            appendLog("Last Workspace could not be restored: \(error.localizedDescription)")
            return false
        }
    }

    private func hideMainWindowForInitialWorkspaceCreation() -> NSWindow? {
        let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first { window in
                window.isVisible && !(window is NSPanel)
            }
        window?.orderOut(nil)
        return window
    }

    @discardableResult
    private func createWorkspaceFromSavePanel() -> Bool {
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
            try replaceWorkspaceStore(store, url: packageURL)
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
        guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
            ?? fileManager.url(forUbiquityContainerIdentifier: nil) else {
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
        let name = workspaceURL?.lastPathComponent
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
        let workspaceName = workspaceURL?.deletingPathExtension().lastPathComponent
            ?? workspaceStore.definition.name
        workspaceStore.edit { definition in
            definition.name = workspaceName
            definition.programs = programLibrary.records
            definition.programArguments = programArgumentsLibrary.records
        }
    }

    private func replaceWorkspaceStore(_ store: WorkspaceStore, url: URL?) throws {
        workspaceStore = store
        workspaceURL = url
        isProgramDefinitionDirty = false
        updateWorkspaceWindowDirtyState()
        let selectedName = store.definition.programs.first?.name
        try programLibrary.replaceRecords(store.definition.programs, selectedName: selectedName)
        try programArgumentsLibrary.replaceRecords(store.definition.programArguments)
        scratchPadProgramArguments = ProgramArguments()
        scratchPadProgramDefinitionRecord = SavedProgramDefinitionRecord(
            name: scratchPadProgramDefinitionName,
            canvasWidth: 1920,
            canvasHeight: 1080,
            frameRateNumerator: 60,
            frameRateDenominator: 1,
            composite: CompositeProgramDefinition()
        )
        selectProgramDefinition(named: selectedName)
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
              saveProgramDefinitionCommand?.isEnabled == true else {
            return
        }
        saveProgramDefinitionCommand?.perform()
    }

    private var saveProgramToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                saveProgramDefinitionCommand?.perform()
            } label: {
                Label("Save Program", systemImage: "square.and.arrow.down")
            }
            .disabled(saveProgramDefinitionCommand?.isEnabled != true)
            .help("Save Program")
        }
    }

    private var isOutputSessionRunning: Bool {
        youtubeStreamingSession?.isRunning == true
    }

    private var isStreamingToYouTube: Bool {
        isOutputSessionRunning && activeCaptureOutputMode?.streamsToYouTube == true
    }

    private var isRecording: Bool {
        isOutputSessionRunning && activeCaptureOutputMode?.recordsLocally == true
    }

    private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord? {
        guard let selectedName = mainWindowState.selectedSavedProgramDefinitionName else {
            return scratchPadProgramDefinitionRecord
        }
        return savedProgramDefinition(named: selectedName)
    }

    private var selectedExistingBroadcast: YouTubeLiveBroadcast? {
        guard let selectedExistingBroadcastID = mainWindowState.selectedExistingBroadcastID else {
            return nil
        }
        return existingBroadcasts.first { $0.id == selectedExistingBroadcastID }
    }

    private var isGlobalOutputSessionStartEnabled: Bool {
        if isLoadingBroadcasts || isConnectingBroadcast {
            return false
        }
        if isOutputSessionRunning {
            return false
        }
        guard canStartProgramAudioMix else {
            return false
        }

        switch mainWindowState.selectedCaptureOutputMode {
        case .youtube, .youtubeAndRecord:
            return selectedExistingBroadcast != nil
        case .record:
            return true
        }
    }

    private var globalOutputSessionStartAccessibilityLabel: String {
        switch mainWindowState.selectedCaptureOutputMode {
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
            return "Add and map an audio channel before starting output."
        }
        if mainWindowState.selectedCaptureOutputMode.streamsToYouTube,
           selectedExistingBroadcast == nil {
            return "Select a YouTube broadcast before starting output."
        }

        switch mainWindowState.selectedCaptureOutputMode {
        case .youtube:
            return "Start streaming to the selected YouTube broadcast."
        case .record:
            return "Start local recording."
        case .youtubeAndRecord:
            return "Start streaming to YouTube and recording locally."
        }
    }

    private var canStartProgramAudioMix: Bool {
        guard !compositeProgramDefinition.audioChannels.isEmpty else {
            return false
        }

        for channel in compositeProgramDefinition.audioChannels
            where channel.component.definition.usesInputAudioDevice {
            let key = compositeProgramDefinition.inputAudioDeviceMappingKey(for: channel)
            guard inputAudioDeviceMappings[key]?.isEmpty == false else {
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
            if let selectedName = mainWindowState.selectedSavedProgramDefinitionName {
                if let record = savedProgramDefinition(named: selectedName) {
                    compositeProgramDefinition = record.composite
                    programArguments = programArgumentsLibrary.arguments(named: record.name) ?? ProgramArguments()
                } else {
                    selectProgramDefinition(named: nil)
                }
            }
        } catch {
            programLibrary.resetAfterRestoreFailure()
            programArgumentsLibrary.resetAfterRestoreFailure()
            selectProgramDefinition(named: nil)
            appendLog("Stored program definitions could not be restored and were reset.")
        }
    }

    private func reloadProgramArguments() {
        do {
            try programArgumentsLibrary.reload()
            if let selectedName = mainWindowState.selectedSavedProgramDefinitionName {
                programArguments = programArgumentsLibrary.arguments(named: selectedName) ?? ProgramArguments()
            }
        } catch {
            programArgumentsLibrary.resetAfterRestoreFailure()
            programArguments = ProgramArguments()
            appendLog("Stored program arguments could not be restored and were reset.")
        }
    }

    private func selectProgramDefinition(named name: String?) {
        mainWindowState.selectedSidebarItem = .program
        mainWindowState.selectedSavedProgramDefinitionName = name
        if let record = savedProgramDefinition(named: name) {
            compositeProgramDefinition = record.composite
            programArguments = programArgumentsLibrary.arguments(named: record.name) ?? ProgramArguments()
        } else if name == nil {
            compositeProgramDefinition = scratchPadProgramDefinitionRecord.composite
            programArguments = scratchPadProgramArguments
        }
        refreshAutomationSelectedProgram()
    }

    private func refreshAutomationSelectedProgram() {
        let isScratchPad = mainWindowState.selectedSavedProgramDefinitionName == nil
        let name = selectedProgramDefinitionRecord?.name ?? scratchPadProgramDefinitionName
        automationState.updateSelectedProgram(name: name, isScratchPad: isScratchPad)
    }

    private func configureAutomationHandlers() {
        automationState.updateHandlers(AppAutomationHandlers(
            terminate: {
                appendLog("Automation requested app termination.")
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return AppAutomationCommandResult(ok: true, message: "Termination requested.")
            },
            selectProgram: { name, isScratchPad in
                if isScratchPad || name == scratchPadProgramDefinitionName {
                    selectProgramDefinition(named: nil)
                    return AppAutomationCommandResult(ok: true, message: "Selected scratch pad Program.")
                }

                guard savedProgramDefinition(named: name) != nil else {
                    return AppAutomationCommandResult(ok: false, message: "Program not found: \(name)")
                }
                selectProgramDefinition(named: name)
                return AppAutomationCommandResult(ok: true, message: "Selected Program: \(name)")
            },
            startRecording: {
                guard !isOutputSessionRunning else {
                    if isRecording {
                        return AppAutomationCommandResult(ok: true, message: "Recording is already running.")
                    }
                    return AppAutomationCommandResult(ok: false, message: "Another output session is already running.")
                }

                mainWindowState.selectedCaptureOutputMode = .record
                startRecording()
                return AppAutomationCommandResult(ok: true, message: "Recording start requested.")
            },
            stopRecording: {
                guard isRecording else {
                    return AppAutomationCommandResult(ok: true, message: "Recording is not running.")
                }

                stopRecording()
                return AppAutomationCommandResult(ok: true, message: "Recording stop requested.")
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
        settings.captureOutputMode = mainWindowState.selectedCaptureOutputMode.protoValue

        var youtube = Ldtx_Automation_V1_YouTubeOutputSettings()
        youtube.broadcastSourceMode = mainWindowState.selectedBroadcastSourceMode.protoValue
        youtube.title = streamTitle
        youtube.description_p = streamDescription
        youtube.resolution = mainWindowState.selectedResolution.protoValue
        youtube.frameRate = mainWindowState.selectedFrameRate.protoValue
        youtube.usesTemporaryStream = usesTemporaryStream
        youtube.existingBroadcastID = mainWindowState.selectedExistingBroadcastID ?? ""
        youtube.privacyStatus = mainWindowState.selectedPrivacyStatus.protoValue
        youtube.latencyPreference = mainWindowState.selectedLatencyPreference.protoValue
        settings.youtube = youtube

        var recording = Ldtx_Automation_V1_RecordingOutputSettings()
        recording.baseDirectoryPath = localOutputStore.baseDirectory.path
        settings.recording = recording

        return settings
    }

    private func applyOutputSettings(
        _ settings: Ldtx_Automation_V1_OutputSettings
    ) -> AppAutomationCommandResult {
        guard !isOutputSessionRunning else {
            return AppAutomationCommandResult(
                ok: false,
                message: "Output settings cannot be changed while output is running."
            )
        }

        do {
            if settings.hasCaptureOutputMode {
                mainWindowState.selectedCaptureOutputMode = try CaptureOutputMode(protoValue: settings.captureOutputMode)
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
        if settings.hasBroadcastSourceMode {
            mainWindowState.selectedBroadcastSourceMode = try BroadcastSourceMode(protoValue: settings.broadcastSourceMode)
        }
        if settings.hasTitle {
            streamTitle = settings.title
        }
        if settings.hasDescription_p {
            streamDescription = settings.description_p
        }
        if settings.hasResolution {
            mainWindowState.selectedResolution = try YouTubeLiveStreamResolution(protoValue: settings.resolution)
        }
        if settings.hasFrameRate {
            mainWindowState.selectedFrameRate = try YouTubeLiveStreamFrameRate(protoValue: settings.frameRate)
        }
        if settings.hasUsesTemporaryStream {
            usesTemporaryStream = settings.usesTemporaryStream
        }
        if settings.hasExistingBroadcastID {
            let trimmed = settings.existingBroadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
            mainWindowState.selectedExistingBroadcastID = trimmed.isEmpty ? nil : trimmed
        }
        if settings.hasPrivacyStatus {
            mainWindowState.selectedPrivacyStatus = try YouTubeLiveBroadcastPrivacyStatus(
                protoValue: settings.privacyStatus
            )
        }
        if settings.hasLatencyPreference {
            mainWindowState.selectedLatencyPreference = try YouTubeLiveBroadcastLatencyPreference(
                protoValue: settings.latencyPreference
            )
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
              isDirectory.boolValue else {
            throw OutputSettingsAutomationError("Recording baseDirectoryPath is not a directory: \(trimmed)")
        }
        localOutputStore.selectBaseDirectory(URL(fileURLWithPath: trimmed, isDirectory: true))
    }

    private func restoreOutputSettings() {
        let defaults = UserDefaults.standard
        if let mode = CaptureOutputMode(rawValue: defaults.string(forKey: OutputSettingsStorageKey.captureOutputMode) ?? "") {
            mainWindowState.selectedCaptureOutputMode = mode
        }
        if let mode = BroadcastSourceMode(rawValue: defaults.string(forKey: OutputSettingsStorageKey.broadcastSourceMode) ?? "") {
            mainWindowState.selectedBroadcastSourceMode = mode
        }
        if let resolution = YouTubeLiveStreamResolution(
            rawValue: defaults.string(forKey: OutputSettingsStorageKey.resolution) ?? ""
        ) {
            mainWindowState.selectedResolution = resolution
        }
        if let frameRate = YouTubeLiveStreamFrameRate(
            rawValue: defaults.string(forKey: OutputSettingsStorageKey.frameRate) ?? ""
        ) {
            mainWindowState.selectedFrameRate = frameRate
        }
        if let status = YouTubeLiveBroadcastPrivacyStatus(
            rawValue: defaults.string(forKey: OutputSettingsStorageKey.privacyStatus) ?? ""
        ) {
            mainWindowState.selectedPrivacyStatus = status
        }
        if let latency = YouTubeLiveBroadcastLatencyPreference(
            rawValue: defaults.string(forKey: OutputSettingsStorageKey.latencyPreference) ?? ""
        ) {
            mainWindowState.selectedLatencyPreference = latency
        }
        streamTitle = defaults.string(forKey: OutputSettingsStorageKey.streamTitle) ?? streamTitle
        streamDescription = defaults.string(forKey: OutputSettingsStorageKey.streamDescription) ?? streamDescription
        if defaults.object(forKey: OutputSettingsStorageKey.usesTemporaryStream) != nil {
            usesTemporaryStream = defaults.bool(forKey: OutputSettingsStorageKey.usesTemporaryStream)
        }
        let broadcastID = defaults.string(forKey: OutputSettingsStorageKey.existingBroadcastID) ?? ""
        mainWindowState.selectedExistingBroadcastID = broadcastID.isEmpty ? nil : broadcastID

        if let baseDirectoryPath = defaults.string(forKey: OutputSettingsStorageKey.localOutputBaseDirectoryPath),
           !baseDirectoryPath.isEmpty {
            localOutputStore.selectBaseDirectory(URL(fileURLWithPath: baseDirectoryPath, isDirectory: true))
        }
    }

    private func persistOutputSettings() {
        let defaults = UserDefaults.standard
        defaults.set(mainWindowState.selectedCaptureOutputMode.rawValue, forKey: OutputSettingsStorageKey.captureOutputMode)
        defaults.set(mainWindowState.selectedBroadcastSourceMode.rawValue, forKey: OutputSettingsStorageKey.broadcastSourceMode)
        defaults.set(mainWindowState.selectedResolution.rawValue, forKey: OutputSettingsStorageKey.resolution)
        defaults.set(mainWindowState.selectedFrameRate.rawValue, forKey: OutputSettingsStorageKey.frameRate)
        defaults.set(mainWindowState.selectedPrivacyStatus.rawValue, forKey: OutputSettingsStorageKey.privacyStatus)
        defaults.set(mainWindowState.selectedLatencyPreference.rawValue, forKey: OutputSettingsStorageKey.latencyPreference)
        defaults.set(mainWindowState.selectedExistingBroadcastID ?? "", forKey: OutputSettingsStorageKey.existingBroadcastID)
        defaults.set(streamTitle, forKey: OutputSettingsStorageKey.streamTitle)
        defaults.set(streamDescription, forKey: OutputSettingsStorageKey.streamDescription)
        defaults.set(usesTemporaryStream, forKey: OutputSettingsStorageKey.usesTemporaryStream)
        defaults.set(localOutputStore.baseDirectory.path, forKey: OutputSettingsStorageKey.localOutputBaseDirectoryPath)
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

    private func renameProgramDefinition(oldName: String, to proposedName: String) {
        do {
            let previousNames = Set(programLibrary.records.map(\.name))
            try programLibrary.rename(oldName: oldName, to: proposedName)
            if let renamed = programLibrary.records.first(where: { !previousNames.contains($0.name) }) {
                try programArgumentsLibrary.rename(oldName: oldName, to: renamed.name)
            }
            syncWorkspaceFromCurrentProgramLibrary()
        } catch {
            appendLog("Program definitions could not be saved: \(error.localizedDescription)")
        }
    }

    private func deleteProgramDefinition(named name: String) {
        let deletedSelectedProgram = mainWindowState.selectedSavedProgramDefinitionName == name
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
                selectProgramDefinition(named: nil)
            }
        } catch {
            appendLog("Program definitions could not be saved: \(error.localizedDescription)")
        }
    }

    private func persistCurrentProgramArguments(_ arguments: ProgramArguments) {
        guard let selectedName = mainWindowState.selectedSavedProgramDefinitionName else {
            scratchPadProgramArguments = arguments
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
            composite: compositeProgramDefinition,
            arguments: arguments
        )
    }

    private func restartAudioMonitor() {
        audioMonitorTask?.cancel()
        let composite = compositeProgramDefinition
        let selectedAudioDriverKey = programAudioDriverKey(
            for: .composite,
            composite: composite
        )
        let inputAudioDeviceMappings = inputAudioDeviceMappings
        let programArguments = programArguments
        let audioMonitor = audioMonitor
        let audioPeakMeter = audioPeakMeter
        audioMonitorTask = Task {
            do {
                try await audioMonitor.restart(
                    composite: composite,
                    inputAudioDeviceMappings: inputAudioDeviceMappings,
                    programArguments: programArguments,
                    programAudioDriverKey: selectedAudioDriverKey,
                    peakMeter: audioPeakMeter
                )
            } catch is CancellationError {
            } catch {
                audioPeakMeter.reset()
                appendLog("Audio monitor failed: \(errorDescription(error))")
            }
        }
    }

    private func refreshExistingBroadcasts() {
        Task {
            isLoadingBroadcasts = true
            defer { isLoadingBroadcasts = false }

            do {
                let accessToken = try await authState.validAccessToken(
                    configuration: oauthClientState.configuration
                )
                let broadcasts = try await youtubeClientService.refreshExistingBroadcasts(accessToken: accessToken)
                existingBroadcasts = broadcasts
                if authState.channelID == nil {
                    authState.refreshChannelID(configuration: oauthClientState.configuration)
                }
                appendLog("Loaded \(broadcasts.count) active/upcoming YouTube broadcast(s).")
            } catch {
                appendLog("Broadcast list failed: \(errorDescription(error))")
            }
        }
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
                let channelID = try await youtubeClientService.authenticatedChannelID(accessToken: accessToken)
                authState.refreshChannelID(configuration: oauthClientState.configuration)

                guard let url = youtubeLiveManagementURL(channelID: channelID) else {
                    appendLog("YouTube channel ID is unavailable.")
                    return
                }
                appendLog("Opening YouTube Live management: \(url.absoluteString)")
                NSWorkspace.shared.open(url)
            } catch {
                appendLog("YouTube channel ID lookup failed: \(errorDescription(error))")
            }
        }
    }

    private func connectYouTubeBroadcast(_ broadcast: YouTubeLiveBroadcast) {
        guard let broadcastID = broadcast.id else {
            appendLog("YouTube broadcast is missing an ID.")
            return
        }
        let outputMode = mainWindowState.selectedCaptureOutputMode
        guard outputMode.streamsToYouTube else {
            appendLog("Select YouTube or YouTube+Record before connecting a broadcast.")
            return
        }
        guard !compositeProgramDefinition.audioChannels.isEmpty else {
            appendLog("Add an Audio Channel to the active Program before starting output.")
            return
        }
        guard !isOutputSessionRunning else {
            appendLog("Capture output is already running.")
            return
        }

        Task {
            isConnectingBroadcast = true
            defer { isConnectingBroadcast = false }

            do {
                let snapshot = streamingSnapshot()
                try await requestRequiredCaptureAccess(snapshot: snapshot)
                let accessToken = try await authState.validAccessToken(
                    configuration: oauthClientState.configuration
                )
                mainWindowState.selectedBroadcastSourceMode = .useExisting
                mainWindowState.selectedExistingBroadcastID = broadcastID
                usesTemporaryStream = true

                let result = try await youtubeClientService.createDASHStream(
                    accessToken: accessToken,
                    request: YouTubeClientService.DASHStreamRequest(
                        title: streamTitle,
                        description: streamDescription,
                        resolution: mainWindowState.selectedResolution,
                        frameRate: mainWindowState.selectedFrameRate,
                        usesTemporaryStream: true,
                        sourceMode: .useExisting,
                        existingBroadcastID: broadcastID,
                        privacyStatus: mainWindowState.selectedPrivacyStatus,
                        latencyPreference: mainWindowState.selectedLatencyPreference
                    )
                )
                if authState.channelID == nil {
                    authState.refreshChannelID(configuration: oauthClientState.configuration)
                }
                guard let dashEndpoint = result.dashEndpoint else {
                    appendLog("YouTube LiveStream did not include a DASH endpoint.")
                    return
                }

                let session = youtubeStreamingSession ?? ProgramDASHStreamingSession(
                    cameraInputSource: programCameraInputSource
                )
                youtubeStreamingSession = session
                if outputMode.recordsLocally {
                    localOutputStore.beginAccess()
                }
                let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
                    for: snapshot.definition,
                    composite: snapshot.composite,
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
                        streamStatus = "DASH upload failed"
                        let description = errorDescription(error)
                        let nsError = error as NSError
                        ldtxAppLogger.error("DASH upload failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                        appendLog("DASH upload failed: \(description)")
                        if outputMode.recordsLocally {
                            localOutputStore.endAccess()
                        }
                        activeCaptureOutputMode = nil
                        youtubeStreamingSession = nil
                    }
                )

                activeCaptureOutputMode = outputMode
                streamStatus = "Streaming to \(broadcast.snippet?.title ?? broadcastID)"
                captureStatus = outputMode.recordsLocally ? "Recording" : captureStatus
                appendLog("Connected YouTube broadcast \(broadcastID) to temporary DASH LiveStream \(result.stream.id ?? "(missing stream id)").")
            } catch {
                if outputMode.recordsLocally {
                    localOutputStore.endAccess()
                }
                activeCaptureOutputMode = nil
                youtubeStreamingSession = nil
                streamStatus = "Connect failed"
                let description = errorDescription(error)
                let nsError = error as NSError
                ldtxAppLogger.error("YouTube broadcast connect failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                appendLog("YouTube broadcast connect failed: \(description)")
            }
        }
    }

    private func stopOutputSession() {
        if isStreamingToYouTube {
            stopYouTubeStreaming()
            return
        }
        if isRecording {
            stopRecording()
        }
    }

    private func startOutputSession() {
        switch mainWindowState.selectedCaptureOutputMode {
        case .youtube, .youtubeAndRecord:
            startYouTubeOutput()
        case .record:
            startRecording()
        }
    }

    private func startYouTubeOutput() {
        guard let broadcast = selectedExistingBroadcast else {
            appendLog("Select a YouTube broadcast before starting output.")
            return
        }
        connectYouTubeBroadcast(broadcast)
    }

    private var knownYouTubeChannelID: String? {
        if let channelID = normalizedChannelID(authState.channelID) {
            return channelID
        }
        if let channelID = normalizedChannelID(
            existingBroadcasts
                .first { $0.id == mainWindowState.selectedExistingBroadcastID }?
                .snippet?
                .channelId
        ) {
            return channelID
        }
        return existingBroadcasts
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
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func stopYouTubeStreaming() {
        let outputMode = activeCaptureOutputMode
        youtubeStreamingSession?.stop()
        youtubeStreamingSession = nil
        if outputMode?.recordsLocally == true {
            localOutputStore.endAccess()
        }
        activeCaptureOutputMode = nil
        streamStatus = "Stopped"
        if outputMode?.recordsLocally == true {
            captureStatus = "Idle"
        }
        appendLog(outputMode == .youtubeAndRecord ? "Stopped YouTube DASH upload and recording." : "Stopped YouTube DASH upload.")
    }

    private func startRecording() {
        guard mainWindowState.selectedCaptureOutputMode == .record else {
            appendLog("Select Record before starting local recording.")
            return
        }
        guard !isOutputSessionRunning else {
            appendLog("Capture output is already running.")
            return
        }
        guard !compositeProgramDefinition.audioChannels.isEmpty else {
            appendLog("Add an Audio Channel to the active Program before starting output.")
            return
        }

        Task {
            do {
                let snapshot = streamingSnapshot()
                try await requestRequiredCaptureAccess(snapshot: snapshot)
                let session = youtubeStreamingSession ?? ProgramDASHStreamingSession(
                    cameraInputSource: programCameraInputSource
                )
                youtubeStreamingSession = session
                localOutputStore.beginAccess()
                let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
                    for: snapshot.definition,
                    composite: snapshot.composite,
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
                        captureStatus = "Record failed"
                        let description = errorDescription(error)
                        let nsError = error as NSError
                        ldtxAppLogger.error("Recording failed while running errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
                        appendLog("Recording failed: \(description)")
                        localOutputStore.endAccess()
                        activeCaptureOutputMode = nil
                        youtubeStreamingSession = nil
                    }
                )

                activeCaptureOutputMode = .record
                captureStatus = "Recording"
                appendLog("Recording started.")
            } catch {
                localOutputStore.endAccess()
                activeCaptureOutputMode = nil
                youtubeStreamingSession = nil
                captureStatus = "Record failed"
                let description = errorDescription(error)
                let nsError = error as NSError
                ldtxAppLogger.error("Recording failed while starting errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
                appendLog("Recording failed: \(description)")
            }
        }
    }

    private func stopRecording() {
        youtubeStreamingSession?.stop()
        youtubeStreamingSession = nil
        localOutputStore.endAccess()
        activeCaptureOutputMode = nil
        captureStatus = "Idle"
        appendLog("Recording stopped.")
    }

    private func streamingSnapshot() -> ProgramPreviewSnapshot {
        let size = captureTargetSize(for: mainWindowState.selectedResolution)
        let selectedRecord = selectedProgramDefinitionRecord
        let frameRate = selectedRecord.map {
            max($0.frameRateNumerator / max($0.frameRateDenominator, 1), 1)
        } ?? (mainWindowState.selectedFrameRate == .fps60 ? 60 : 30)
        let definition = ProgramDefinition.composite
        let composite = compositeProgramDefinition
        return ProgramPreviewSnapshot(
            definition: definition,
            composite: composite,
            canvasWidth: programWorldCanvasSize.width,
            canvasHeight: programWorldCanvasSize.height,
            outputWidth: size.width,
            outputHeight: size.height,
            frameRate: frameRate,
            timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
            programVideoPTSInputKey: programVideoPTSInputKey(
                for: definition,
                composite: composite
            ),
            programAudioDriverKey: programAudioDriverKey(
                for: definition,
                composite: composite
            ),
            cameraIDsByInputKey: mappedInputCameraDeviceIDs(
                for: definition,
                composite: composite,
                inputCameraDeviceMappings: inputCameraDeviceMappings
            ),
            backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
                for: definition,
                composite: composite
            )
        )
    }

    private func requestRequiredCaptureAccess(snapshot: ProgramPreviewSnapshot) async throws {
        if snapshot.definition.usesInputCameraDevice(composite: snapshot.composite),
           await requestCaptureAccess(for: .video) == false {
            ldtxAppLogger.error("Camera access preflight failed before starting output.")
            throw CameraCaptureServiceError.cameraAccessDenied
        }

        if snapshot.composite.audioChannels.contains(where: { $0.component.definition.usesInputAudioDevice }),
           await requestCaptureAccess(for: .audio) == false {
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
        appendLog("Capture device list refreshed: \(result.cameras.count) camera(s), \(result.audioDevices.count) audio device(s).")
        appendCaptureDeviceDetails(cameras: result.cameras, audioDevices: result.audioDevices)
        if let device = result.restoredSelectedAudioDevice {
            appendLog("Stored capture audio selected: \(device.name).")
        } else if result.didSelectFallbackForUnavailableStoredAudio {
            appendLog("Stored capture audio device is unavailable; selected fallback audio.")
        } else if let preferredAudioDevice = result.preferredAudioDevice {
            appendLog("Preferred safe capture audio selected: \(preferredAudioDevice.name).")
        }
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
            appendLog("Camera device: name=\(camera.name), type=\(camera.deviceType), modelID=\(camera.modelID), id=\(CaptureDeviceStore.redactedDeviceID(camera.id)), external=\(camera.isExternal), format=\(camera.formatSummary)")
        }
        for device in audioDevices {
            appendLog("Audio device: name=\(device.name), type=\(device.deviceType), modelID=\(device.modelID), id=\(CaptureDeviceStore.redactedDeviceID(device.id)), external=\(device.isExternal), format=\(device.formatSummary)")
        }
    }

    private func appendLog(_ message: String) {
        logStore.append(message)
    }

    private func errorDescription(_ error: Error) -> String {
        if let captureError = error as? CameraCaptureServiceError {
            switch captureError {
            case .microphoneAccessDenied:
                return "\(captureError.localizedDescription) Allow Microphone access for LDTX in System Settings > Privacy & Security > Microphone, then restart the app."
            case .cameraAccessDenied:
                return "\(captureError.localizedDescription) Allow Camera access for LDTX in System Settings > Privacy & Security > Camera, then restart the app."
            default:
                return captureError.localizedDescription
            }
        }
        if let youtubeError = error as? YouTubeLiveAPIError,
           let responseBody = youtubeError.responseBodyString,
           !responseBody.isEmpty {
            return "\(youtubeError.localizedDescription) Body: \(responseBody)"
        }
        return error.localizedDescription
    }
}

private struct OutputSettingsAutomationError: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

private extension CaptureOutputMode {
    var protoValue: Ldtx_Automation_V1_CaptureOutputMode {
        switch self {
        case .youtube:
            .youtube
        case .record:
            .record
        case .youtubeAndRecord:
            .youtubeAndRecord
        }
    }

    init(protoValue: Ldtx_Automation_V1_CaptureOutputMode) throws {
        switch protoValue {
        case .youtube:
            self = .youtube
        case .record:
            self = .record
        case .youtubeAndRecord:
            self = .youtubeAndRecord
        case .unspecified, .UNRECOGNIZED:
            throw OutputSettingsAutomationError("captureOutputMode must be youtube, record, or youtubeAndRecord.")
        }
    }
}

private extension BroadcastSourceMode {
    var protoValue: Ldtx_Automation_V1_BroadcastSourceMode {
        switch self {
        case .createNew:
            .createNew
        case .useExisting:
            .useExisting
        }
    }

    init(protoValue: Ldtx_Automation_V1_BroadcastSourceMode) throws {
        switch protoValue {
        case .createNew:
            self = .createNew
        case .useExisting:
            self = .useExisting
        case .unspecified, .UNRECOGNIZED:
            throw OutputSettingsAutomationError("youtube.broadcastSourceMode must be createNew or useExisting.")
        }
    }
}

private extension YouTubeLiveStreamResolution {
    var protoValue: Ldtx_Automation_V1_YouTubeLiveStreamResolution {
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

    init(protoValue: Ldtx_Automation_V1_YouTubeLiveStreamResolution) throws {
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
            throw OutputSettingsAutomationError("youtube.resolution must be p240, p360, p480, p720, p1080, p1440, or p2160.")
        }
    }
}

private extension YouTubeLiveStreamFrameRate {
    var protoValue: Ldtx_Automation_V1_YouTubeLiveStreamFrameRate {
        switch self {
        case .fps30:
            .fps30
        case .fps60:
            .fps60
        }
    }

    init(protoValue: Ldtx_Automation_V1_YouTubeLiveStreamFrameRate) throws {
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

private extension YouTubeLiveBroadcastPrivacyStatus {
    var protoValue: Ldtx_Automation_V1_YouTubeLiveBroadcastPrivacyStatus {
        switch self {
        case .private:
            .private
        case .unlisted:
            .unlisted
        case .public:
            .public
        }
    }

    init(protoValue: Ldtx_Automation_V1_YouTubeLiveBroadcastPrivacyStatus) throws {
        switch protoValue {
        case .private:
            self = .private
        case .unlisted:
            self = .unlisted
        case .public:
            self = .public
        case .unspecified, .UNRECOGNIZED:
            throw OutputSettingsAutomationError("youtube.privacyStatus must be private, unlisted, or public.")
        }
    }
}

private extension YouTubeLiveBroadcastLatencyPreference {
    var protoValue: Ldtx_Automation_V1_YouTubeLiveBroadcastLatencyPreference {
        switch self {
        case .normal:
            .normal
        case .low:
            .low
        case .ultraLow:
            .ultraLow
        }
    }

    init(protoValue: Ldtx_Automation_V1_YouTubeLiveBroadcastLatencyPreference) throws {
        switch protoValue {
        case .normal:
            self = .normal
        case .low:
            self = .low
        case .ultraLow:
            self = .ultraLow
        case .unspecified, .UNRECOGNIZED:
            throw OutputSettingsAutomationError("youtube.latencyPreference must be normal, low, or ultraLow.")
        }
    }
}

private struct OutputSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var oauthClientState: OAuthClientState
    @ObservedObject var authState: YouTubeAuthState
    var streamStatus: String
    var captureStatus: String
    @Binding var mainWindowState: MainWindowState
    @Binding var streamTitle: String
    @Binding var streamDescription: String
    @Binding var usesTemporaryStream: Bool
    var existingBroadcasts: [YouTubeLiveBroadcast]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var localOutputStore: LocalOutputStore
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ContentSettingsForm(
                    oauthClientStatus: oauthClientState.status,
                    authorizationStatus: authState.status,
                    streamStatus: streamStatus,
                    captureStatus: captureStatus,
                    mainWindowState: $mainWindowState,
                    streamTitle: $streamTitle,
                    streamDescription: $streamDescription,
                    usesTemporaryStream: $usesTemporaryStream,
                    existingBroadcasts: existingBroadcasts,
                    isLoadingBroadcasts: isLoadingBroadcasts,
                    isConnectingBroadcast: isConnectingBroadcast,
                    isStreamingToYouTube: isStreamingToYouTube,
                    isRecording: isRecording,
                    localOutputStore: localOutputStore,
                    refreshExistingBroadcasts: refreshExistingBroadcasts,
                    manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                    chooseLocalOutputDirectory: chooseLocalOutputDirectory,
                    placement: .modal
                )
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
    }
}
