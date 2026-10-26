// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AVKit
import LDTXCorelibs
import LDTXRecording
import OSLog
import Observation
import SwiftUI

private let recordingPreviewLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "RecordingPreview"
)

public typealias LDTXRecordPlayerAssetLoader =
  @MainActor @Sendable (URL, RecordingCanvas?) async throws -> AVAsset

public struct LDTXRecordPlayerView: View {
  private weak var document: RecordPlayerDocument?
  private var markers: [RecordingMarker] { document?.markers ?? [] }
  private var canModifyMarkers: Bool { document?.canModifyMarkers == true }
  @State private var pendingMarkerDeletion: RecordingMarker?
  @Bindable private var model: LDTXRecordPlayerModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
  @State private var isInspectorPresented = true
  @State private var selectedFeature: PlayerFeature? = .markers
  private let requestClose: () -> Void
  @Environment(\.undoManager) private var undoManager
  @State private var pendingMarkerTime: CMTime?
  @State private var pendingTimecodeText = ""
  @State private var markerNote = ""
  @State private var markerError: String?
  @State private var selectedMarkerID: String?
  @FocusState private var focusedMarkerField: MarkerField?

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      featureSidebar
        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
    } detail: {
      playerContent
        .frame(minWidth: 400, minHeight: 360)
    }
    .inspector(isPresented: $isInspectorPresented) {
      featureDetail
        .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isInspectorPresented.toggle()
        } label: {
          Label("Toggle Inspector", systemImage: "sidebar.right")
        }
      }
    }
    .focusedSceneValue(\.recordPlayerInspector, $isInspectorPresented)
    .task { model.start() }
    .onChange(of: model.shouldClose, initial: true) { _, shouldClose in
      if shouldClose { requestClose() }
    }
    .alert(
      model.alert?.title ?? "Error",
      isPresented: Binding(
        get: { model.alert != nil },
        set: { if !$0 { model.alert = nil } }),
      presenting: model.alert
    ) { pending in
      Button("OK") {
        model.alert = nil
        if pending.closeAfterDismissal { requestClose() }
      }
    } message: { pending in
      Text(pending.message)
    }
    .onChange(of: markers.map(\.fileName)) { _, names in
      if let selectedMarkerID, !names.contains(selectedMarkerID) { self.selectedMarkerID = nil }
    }
  }

  init(
    model: LDTXRecordPlayerModel, document: RecordPlayerDocument,
    requestClose: @escaping () -> Void
  ) {
    self.document = document
    self.model = model
    self.requestClose = requestClose
  }

  private var featureSidebar: some View {
    List(selection: $selectedFeature) {
      Label("Markers", systemImage: "bookmark")
        .tag(PlayerFeature.markers)
    }
    .listStyle(.sidebar)
    .navigationTitle("Player")
  }

  private var playerContent: some View {
    VStack(spacing: 0) {
      if model.availableCanvases.count > 1 {
        Picker("Canvas", selection: $model.selectedCanvas) {
          ForEach(model.availableCanvases, id: \.self) { canvas in
            Text(canvas == .landscape ? "Landscape" : "Portrait").tag(canvas)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .padding(8)
        .onChange(of: model.selectedCanvas) { _, canvas in
          model.selectCanvas(canvas)
        }
      }
      ZStack {
        VideoPlayer(player: model.player)
          .overlay(alignment: .topLeading) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
              Text(Self.displayTimecode(model.player?.currentTime() ?? .zero) ?? "00:00:00.000")
                .font(.caption.monospacedDigit())
                .padding(4)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(8)
            }
          }

        if model.isLoading {
          ProgressView("Loading Recording…")
            .controlSize(.large)
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
      }
      markerBar
    }
  }

  @ViewBuilder
  private var featureDetail: some View {
    switch selectedFeature {
    case .some(.markers):
      markerList
    case nil:
      ContentUnavailableView(
        "No Feature Selected",
        systemImage: "sidebar.left",
        description: Text("Select a feature in the sidebar.")
      )
    }
  }

  private var markerBar: some View {
    HStack(spacing: 8) {
      TextField("HH:MM:SS.mmm", text: pendingTimecodeBinding)
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.center)
        .foregroundStyle(pendingMarkerTime == nil ? Color.primary : Color.green)
        .frame(width: 116)
        .focused($focusedMarkerField, equals: .timecode)
        .onSubmit(commitPendingTimecode)

      TextField("Add a marker note…", text: $markerNote)
        .focused($focusedMarkerField, equals: .note)
        .onSubmit(submitMarker)
        .onChange(of: markerNote) { _, _ in markerError = nil }

      if let markerError {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
          .help(markerError)
      }
    }
    .textFieldStyle(.roundedBorder)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .overlay(alignment: .top) { Divider() }
    .disabled(!model.isLoaded || !canModifyMarkers)
    .onChange(of: focusedMarkerField) { oldValue, newValue in
      guard oldValue == .timecode, newValue != .timecode else { return }
      pendingTimecodeText = pendingMarkerTime.flatMap(Self.displayTimecode) ?? ""
    }
    .onKeyPress(.escape) {
      clearPendingMarkerTime()
      return .handled
    }
  }

  private var pendingTimecodeBinding: Binding<String> {
    Binding(
      get: { pendingTimecodeText },
      set: { newValue in
        pendingTimecodeText = newValue
        markerError = nil
        if pendingMarkerTime.flatMap(Self.displayTimecode) != newValue {
          pendingMarkerTime = nil
        }
      }
    )
  }

  private func submitMarker() {
    guard let player = model.player else { return }
    guard !markerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      setPendingMarkerTime(player.currentTime())
      return
    }

    guard let document else { return }
    do {
      try document.createMarker(
        note: markerNote, at: pendingMarkerTime ?? player.currentTime(), undoManager: undoManager)
    } catch {
      presentMarkerFileError(title: "Marker Could Not Be Added", error: error)
      return
    }
    markerNote = ""
    markerError = nil
    clearPendingMarkerTime()
  }

  private func commitPendingTimecode() {
    guard
      let time = Self.time(fromDisplayTimecode: pendingTimecodeText),
      model.durationSeconds <= 0 || Self.validSeconds(time) <= model.durationSeconds
    else {
      markerError = "Enter a valid recording time in HH:MM:SS.mmm format."
      NSSound.beep()
      return
    }
    setPendingMarkerTime(time)
  }

  private func setPendingMarkerTime(_ time: CMTime) {
    guard let timecode = Self.displayTimecode(time) else { return }
    pendingMarkerTime = time
    pendingTimecodeText = timecode
    markerError = nil
  }

  private func clearPendingMarkerTime() {
    pendingMarkerTime = nil
    pendingTimecodeText = ""
    markerError = nil
  }

  private static func displayTimecode(_ time: CMTime) -> String? {
    try? RecordingMarkerStore.displayTimecode(for: time)
  }

  private static func validSeconds(_ time: CMTime) -> Double {
    let seconds = time.seconds
    return seconds.isFinite && seconds >= 0 ? seconds : 0
  }

  private static func time(fromDisplayTimecode timecode: String) -> CMTime? {
    let components = timecode.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 3,
      let hours = Int64(components[0]),
      (0...999_999).contains(hours),
      let minutes = Int64(components[1]),
      (0..<60).contains(minutes)
    else { return nil }

    let secondComponents = components[2].split(separator: ".", omittingEmptySubsequences: false)
    guard secondComponents.count == 2,
      secondComponents[1].count == 3,
      let seconds = Int64(secondComponents[0]),
      let milliseconds = Int64(secondComponents[1]),
      (0..<60).contains(seconds),
      (0..<1_000).contains(milliseconds)
    else { return nil }

    let totalMilliseconds =
      hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds
    return CMTime(value: totalMilliseconds, timescale: 1_000)
  }

  private enum MarkerField: Hashable {
    case timecode
    case note
  }

  enum PlayerFeature: Hashable {
    case markers
  }

  private var markerList: some View {
    VStack(alignment: .leading, spacing: 0) {
      Group {
        if markers.isEmpty {
          ContentUnavailableView(
            "No Markers",
            systemImage: "bookmark",
            description: Text("Saved markers appear here.")
          )
        } else {
          List(markers, id: \.fileName, selection: $selectedMarkerID) { marker in
            Button {
              selectedMarkerID = marker.fileName
              model.seek(to: marker.time)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                  Image(systemName: "bookmark.fill")
                  Text(marker.timecode)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                }
                .foregroundStyle(.secondary)
                Text(marker.note)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Go to \(marker.timecode)")
            .tag(marker.fileName)
            .contextMenu {
              Button(role: .destructive) {
                pendingMarkerDeletion = marker
              } label: {
                Label("Delete Marker", systemImage: "trash")
              }
              .disabled(!canModifyMarkers)
            }
          }
          .listStyle(.inset)
          .onDeleteCommand(perform: deleteSelectedMarker)
        }
      }
    }
    .alert(
      "Delete Marker?",
      isPresented: Binding(
        get: { pendingMarkerDeletion != nil },
        set: { if !$0 { pendingMarkerDeletion = nil } }
      ), presenting: pendingMarkerDeletion
    ) { marker in
      Button("Delete", role: .destructive) { deleteMarker(marker) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("You can undo this deletion. The marker file is removed when the document is saved.")
    }
  }

  private func deleteSelectedMarker() {
    guard
      canModifyMarkers,
      let selectedMarkerID,
      let marker = markers.first(where: { $0.fileName == selectedMarkerID })
    else { return }
    pendingMarkerDeletion = marker
  }

  private func deleteMarker(_ marker: RecordingMarker) {
    guard canModifyMarkers else { return }
    guard let document else { return }
    do {
      try document.deleteMarker(marker, undoManager: undoManager)
    } catch {
      presentMarkerFileError(title: "Marker Could Not Be Deleted", error: error)
      return
    }
    if selectedMarkerID == marker.fileName {
      selectedMarkerID = nil
    }
    markerError = nil
  }

  private func presentMarkerFileError(title: String, error: any Error) {
    recordingPreviewLogger.error(
      "Marker file operation failed: \((error as NSError).domain, privacy: .private) code=\((error as NSError).code, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
    )
    model.alert = LDTXRecordPlayerAlert(
      title: title,
      message: error.localizedDescription
    )
  }

}

@MainActor
@Observable
final class LDTXRecordPlayerModel {
  var player: AVPlayer?
  var alert: LDTXRecordPlayerAlert?
  var isLoading = true
  var shouldClose = false
  var durationSeconds = 0.0
  var availableCanvases: [RecordingCanvas] = []
  var selectedCanvas: RecordingCanvas = .landscape

  private weak var document: RecordPlayerDocument?
  private let scenarioFixture: RecordingPreviewScenarioFixture?
  private let assetLoader: LDTXRecordPlayerAssetLoader
  private var loadTask: Task<Void, Never>?
  private var isStopped = false

  init(
    document: RecordPlayerDocument,
    scenarioFixture: RecordingPreviewScenarioFixture?,
    assetLoader: @escaping LDTXRecordPlayerAssetLoader
  ) {
    self.document = document
    self.scenarioFixture = scenarioFixture
    self.assetLoader = assetLoader
  }

  var isLoaded: Bool {
    player != nil
  }

  func start() {
    guard !isStopped, loadTask == nil else { return }
    loadTask = Task { await load() }
  }

  func stop() {
    isStopped = true
    loadTask?.cancel()
    player?.pause()
    player = nil
  }

  func selectCanvas(_ canvas: RecordingCanvas) {
    guard !isStopped, availableCanvases.contains(canvas) else { return }
    let resumeTime = player?.currentTime() ?? .zero
    let resumesPlayback = player?.timeControlStatus == .playing
    player?.pause()
    player = nil
    isLoading = true
    loadTask?.cancel()
    loadTask = Task { await load(resumeAt: resumeTime, startsPlaying: resumesPlayback) }
  }

  func seek(to time: CMTime) {
    player?.currentItem?.cancelPendingSeeks()
    player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  private func load(resumeAt: CMTime = .zero, startsPlaying: Bool = true) async {
    guard let recordingURL = document?.fileURL else {
      isLoading = false
      return
    }
    recordingPreviewLogger.info(
      "Loading recording preview"
    )
    if await loadScenarioFixtureIfNeeded() { return }

    do {
      let package = try RecordingPackage(contentsOf: recordingURL)
      availableCanvases = package.availableCanvases.filter { canvas in
        guard let media = package.media(for: canvas) else { return false }
        return FileManager.default.fileExists(atPath: media.url.path)
      }
      if !availableCanvases.isEmpty, !availableCanvases.contains(selectedCanvas) {
        selectedCanvas = availableCanvases[0]
      }
      let selected = package.formatVersion >= 3 ? selectedCanvas : nil
      let asset = try await assetLoader(recordingURL, selected)
      guard !Task.isCancelled else { return }

      let duration = try await asset.load(.duration)
      guard !Task.isCancelled else { return }
      durationSeconds = Self.validSeconds(duration)
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      self.player = player
      isLoading = false
      if resumeAt > .zero {
        await player.seek(to: resumeAt)
      }
      guard !Task.isCancelled else { return }
      if startsPlaying { player.play() }
    } catch {
      guard !Task.isCancelled else { return }
      isLoading = false
      recordingPreviewLogger.error(
        "Recording preview load failed: \((error as NSError).domain, privacy: .private) code=\((error as NSError).code, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
      )
      alert = LDTXRecordPlayerAlert(
        title: "Recording Could Not Be Opened",
        message: error.localizedDescription,
        closeAfterDismissal: true
      )
    }
  }

  private func closeAfterInternalError(_ message: String) {
    recordingPreviewLogger.error(
      "Recording preview internal failure: \(message, privacy: .private)")
    shouldClose = true
  }

  private static func validSeconds(_ time: CMTime) -> Double {
    let seconds = time.seconds
    return seconds.isFinite && seconds >= 0 ? seconds : 0
  }

  private func loadScenarioFixtureIfNeeded() async -> Bool {
    guard let scenarioFixture else { return false }
    recordingPreviewLogger.notice(
      "Activating recording preview fixture \(scenarioFixture.rawValue, privacy: .public)"
    )

    switch scenarioFixture {
    case .initialLoadFailure:
      isLoading = false
      alert = LDTXRecordPlayerAlert(
        title: "Recording Could Not Be Opened",
        message: "The scenario fixture could not open the recording.",
        closeAfterDismissal: true
      )
    case .internalStateFailure:
      await Task.yield()
      closeAfterInternalError("The internal-state-failure scenario fixture was activated.")
    }
    return true
  }
}

struct LDTXRecordPlayerAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  var closeAfterDismissal = false
}
