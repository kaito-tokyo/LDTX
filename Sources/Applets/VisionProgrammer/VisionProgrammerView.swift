// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CreateMLComponents
import LDTXVisionTraining
import SwiftUI
import UniformTypeIdentifiers

public struct VisionProgrammerView: View {
  public static let id = "vision-programmer"

  @State private var datasetURL: URL?
  @State private var iterations = 25
  @State private var isBusy = false
  @State private var status: String
  @State private var selectedVision: VisionKind? = .sceneDetector

  @State private var isShowingTrainingSheet = false
  @State private var trainingProgress: Progress?
  @State private var modelFile: ModelFile?
  @State private var modelFileName = "SceneDetector.mlpackage"
  @State private var isShowingFileExporter = false
  @State private var error: Error?
  @State private var isShowingError = false

  public init(
    datasetURL: URL? = nil,
    isBusy: Bool = false,
    status: String = "Choose a dataset to begin."
  ) {
    _datasetURL = State(initialValue: datasetURL)
    _isBusy = State(initialValue: isBusy)
    _status = State(initialValue: status)
  }

  public var body: some View {
    NavigationSplitView {
      List(selection: $selectedVision) {
        Text("Scene Detector")
          .tag(VisionKind.sceneDetector)
      }
      .navigationTitle("Vision Types")
      .navigationSplitViewColumnWidth(min: 160, ideal: 180)
    } detail: {
      switch selectedVision {
      case .sceneDetector: sceneDetectorContent
      case nil:
        ContentUnavailableView("Choose a Vision type", systemImage: "eye")
      }
    }
    .alert("Error", isPresented: $isShowingError, presenting: error) { _ in
      Button("OK") { error = nil }
    } message: { error in
      Text(error.localizedDescription)
    }
  }

  var sceneDetectorContent: some View {
    Form {
      Section("Dataset loading") {
        LabeledContent("Dataset") {
          FolderPathPicker(
            placeholderString: String(localized: "Choose a folder…"),
            folderURL: $datasetURL)
        }
      }

      Section("Training parameters") {
        LabeledContent("Extractor", value: "Image Feature Print V2")
        TextField("Iterations", value: $iterations, format: .number.grouping(.never))
      }
    }
    .formStyle(.grouped)
    .disabled(isBusy)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          guard let datasetURL else { return }
          let iterations = iterations
          Task { await train(datasetURL: datasetURL, iterations: iterations) }
        } label: {
          Label("Start training", systemImage: "play.fill")
        }
        .disabled(datasetURL == nil || isBusy)
      }
    }
    .sheet(
      isPresented: $isShowingTrainingSheet,
      onDismiss: {
        if modelFile != nil {
          isShowingFileExporter = true
        } else if error != nil {
          isShowingError = true
        }
      }
    ) {
      if let trainingProgress {
        TrainingSheet(progress: trainingProgress, isBusy: isBusy) {
          isShowingTrainingSheet = false
        }
        .interactiveDismissDisabled(isBusy)
      }
    }
    .fileExporter(
      isPresented: $isShowingFileExporter,
      document: modelFile,
      contentType: ModelFile.contentType,
      defaultFilename: modelFileName
    ) { result in
      switch result {
      case .success(let url): status = "Saved \(url.lastPathComponent)"
      case .failure(let error):
        self.error = error
        isShowingError = true
      }
    }
    .navigationTitle("Scene Detector")
  }

  private func train(datasetURL: URL, iterations: Int) async {
    let hasAccess = datasetURL.startAccessingSecurityScopedResource()
    defer { if hasAccess { datasetURL.stopAccessingSecurityScopedResource() } }
    modelFile = nil
    error = nil
    modelFileName = "\(datasetURL.lastPathComponent).mlpackage"
    status = "Preparing training…"
    isBusy = true
    defer { isBusy = false }
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let trainer = try await LDTXSceneDetectorTrainer.prepare(
        at: datasetURL, maxIterations: iterations, cropAndScale: .scaleFit)
      let progress = Progress.discreteProgress(totalUnitCount: 100)
      progress.isCancellable = false
      progress.isPausable = false
      progress.localizedDescription = String(localized: "Extracting features…")
      let extraction = Progress(
        totalUnitCount: Int64(trainer.files.count), parent: progress, pendingUnitCount: 70)
      let fitting = Progress(totalUnitCount: -1, parent: progress, pendingUnitCount: 25)
      let exporting = Progress(totalUnitCount: 1, parent: progress, pendingUnitCount: 5)
      for child in [extraction, fitting, exporting] {
        child.isCancellable = false
        child.isPausable = false
      }

      let eventHandler: EventHandler = { event in
        if event.origin.contains("ImageFeaturePrint") {
          progress.localizedDescription = String(localized: "Extracting features…")
          extraction.completedUnitCount = min(
            extraction.totalUnitCount, Int64(max(0, event.itemCount)))
        } else {
          extraction.completedUnitCount = extraction.totalUnitCount
          progress.localizedDescription = String(localized: "Training classifier…")
          if let total = event.totalItemCount, total > 0 {
            fitting.totalUnitCount = Int64(total)
            fitting.completedUnitCount = Int64(min(total, max(0, event.itemCount)))
          } else {
            fitting.totalUnitCount = -1
          }
        }
      }

      trainingProgress = progress
      isShowingTrainingSheet = true
      let url = try await trainer.fit(
        to: directory.appendingPathComponent("SceneDetector.mlpackage", isDirectory: true),
        eventHandler: eventHandler)
      modelFile = try await ModelFile.load(at: url)
      extraction.completedUnitCount = extraction.totalUnitCount
      if fitting.totalUnitCount <= 0 { fitting.totalUnitCount = 1 }
      fitting.completedUnitCount = fitting.totalUnitCount
      exporting.completedUnitCount = 1
      progress.localizedDescription = String(localized: "Training completed.")
      status = "Training completed."
      isShowingTrainingSheet = false
    } catch {
      status = "Training failed."
      self.error = error
      if isShowingTrainingSheet {
        isShowingTrainingSheet = false
      } else {
        isShowingError = true
      }
    }
  }

  struct TrainingSheet: View {
    let progress: Progress
    var isBusy = true
    var done: () -> Void = {}

    var body: some View {
      VStack(spacing: 16) {
        Text("Training").font(.headline)
        ProgressView(progress).progressViewStyle(.linear)
        if !isBusy {
          Button("Done", action: done)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding()
      .frame(minWidth: 320)
    }
  }

  enum VisionKind: Hashable {
    case sceneDetector
  }

  private struct ModelFile: FileDocument {
    static let contentType = UTType(filenameExtension: "mlpackage", conformingTo: .package)!
    static var readableContentTypes: [UTType] { [contentType] }
    let wrapper: FileWrapper

    @concurrent static func load(at url: URL) async throws -> sending ModelFile {
      try ModelFile(url: url)
    }

    init(url: URL) throws {
      wrapper = try FileWrapper(url: url, options: .immediate)
      wrapper.preferredFilename = "SceneDetector.mlpackage"
    }

    init(configuration: ReadConfiguration) throws {
      wrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
      wrapper
    }
  }
}

private struct FolderPathPicker: NSViewRepresentable {
  let placeholderString: String?
  @Binding var folderURL: URL?

  func makeNSView(context: Context) -> NSPathControl {
    let control = NSPathControl()
    control.pathStyle = .popUp
    control.isEditable = true
    control.placeholderString = placeholderString
    control.delegate = context.coordinator
    control.target = context.coordinator
    control.action = #selector(Coordinator.pathChanged(_:))
    return control
  }

  func updateNSView(_ control: NSPathControl, context: Context) {
    context.coordinator.folderURL = $folderURL
    control.url = folderURL
  }

  func makeCoordinator() -> Coordinator { Coordinator(folderURL: $folderURL) }

  final class Coordinator: NSObject, NSPathControlDelegate {
    var folderURL: Binding<URL?>

    init(folderURL: Binding<URL?>) { self.folderURL = folderURL }

    @MainActor @objc func pathChanged(_ control: NSPathControl) {
      folderURL.wrappedValue = control.url
    }

    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
      openPanel.canChooseFiles = false
      openPanel.canChooseDirectories = true
      openPanel.allowsMultipleSelection = false
      openPanel.allowedContentTypes = []
    }
  }
}

#if DEBUG
  #Preview {
    VisionProgrammerView()
  }
#endif
