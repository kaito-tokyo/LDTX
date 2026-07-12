// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXProgram
import LDTXProgramRendering
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXVideoComposition
import LDTXVideoRendering
import MetalKit
import SwiftUI

struct ProgramPreviewPane: View {
    var title: String?
    var outputCanvas: OutputCanvasModel
    var outputDestination: OutputDestinationModel
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    var activeProgramRuntime: ActiveProgramRuntime?
    var activeProgramSnapshot: ProgramPreviewSnapshot?
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var compositeProgramDefinition: CompositeProgramDefinition
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var workspaceAudioChannels: [ProgramAudioChannel]
    var inputCameraDeviceMappings: [String: String]
    @StateObject private var previewController: ProgramPreviewController

    init(
        title: String? = nil,
        outputCanvas: OutputCanvasModel,
        outputDestination: OutputDestinationModel,
        workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        activeProgramRuntime: ActiveProgramRuntime? = nil,
        activeProgramSnapshot: ProgramPreviewSnapshot? = nil,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        compositeProgramDefinition: CompositeProgramDefinition,
        workspaceInputDevices: [WorkspaceInputDeviceRecord],
        workspaceAudioChannels: [ProgramAudioChannel],
        inputCameraDeviceMappings: [String: String]
    ) {
        self.title = title
        self.outputCanvas = outputCanvas
        self.outputDestination = outputDestination
        self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
        self.activeProgramRuntime = activeProgramRuntime
        self.activeProgramSnapshot = activeProgramSnapshot
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.compositeProgramDefinition = compositeProgramDefinition
        self.workspaceInputDevices = workspaceInputDevices
        self.workspaceAudioChannels = workspaceAudioChannels
        self.inputCameraDeviceMappings = inputCameraDeviceMappings
        if let activeProgramRuntime {
            _previewController = StateObject(
                wrappedValue: ProgramPreviewController(activeProgramRuntime: activeProgramRuntime)
            )
        } else {
            _previewController = StateObject(
                wrappedValue: ProgramPreviewController(
                    captureSessionCoordinator: workspaceCaptureSessionCoordinator
                )
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title ?? selectedProgramDefinitionRecord?.name ?? "Program Video Components")
                    .font(.headline)
                Spacer()
                Text(previewStatus)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ZStack {
                Rectangle()
                    .fill(.black)
                ProgramPixelBufferPreview(
                    controller: previewController,
                    frameRate: previewFrameRate,
                    mode: previewMode,
                    taskPriority: .utility
                )
            }
            .aspectRatio(Double(previewSize.width) / Double(previewSize.height), contentMode: .fit)
            .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                previewModePicker
            }
        }
        .onAppear {
            configurePreview()
        }
        .onChange(of: selectedProgramDefinitionRecord) { _, _ in configurePreview() }
        .onChange(of: compositeProgramDefinition) { _, _ in configurePreview() }
        .onChange(of: outputCanvas.state) { _, _ in configurePreview() }
        .onChange(of: workspaceInputDevices) { _, _ in configurePreview() }
        .onChange(of: workspaceAudioChannels) { _, _ in configurePreview() }
        .onChange(of: inputCameraDeviceMappings) { _, _ in configurePreview() }
        .onChange(of: outputDestination.prefersColorPreview) { _, _ in configurePreview() }
    }

    private var previewModePicker: some View {
        Picker("Preview Mode", selection: previewModeSelection) {
            Text("Lightweight").tag(ProgramPixelBufferPreviewMode.lightweight)
            Text("Accurate").tag(ProgramPixelBufferPreviewMode.color)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("programPreviewModePicker")
    }

    private var previewModeSelection: Binding<ProgramPixelBufferPreviewMode> {
        Binding {
            previewMode
        } set: { mode in
            outputDestination.prefersColorPreview = mode == .color
        }
    }

    private var previewSize: (width: Int, height: Int) {
        (outputCanvas.canvasSize.width, outputCanvas.canvasSize.height)
    }

    private var previewFrameRate: Int {
        let frameRate = max(activeProgramSnapshot?.frameRate ?? outputCanvas.programDefinitionFrameRate, 1)
        return previewMode == .lightweight ? min(frameRate, 15) : frameRate
    }

    private var previewMode: ProgramPixelBufferPreviewMode {
        outputDestination.prefersColorPreview ? .color : .lightweight
    }

    private var previewStatus: String {
        "\(previewSize.width)x\(previewSize.height) @ \(previewFrameRate) fps"
    }

    @MainActor
    private func configurePreview() {
        let snapshot = activeProgramSnapshot ?? previewSnapshot()
        previewController.configure(snapshot: snapshot)
    }

    @MainActor
    private func previewSnapshot() -> ProgramPreviewSnapshot {
        let size = previewSize
        let definition = ProgramDefinition.composite
        let composite = outputCanvas.applying(to: compositeProgramDefinition)
        let cameraIDsByInputKey = mappedInputCameraDeviceIDs(
            for: definition,
            composite: composite,
            workspaceInputDevices: workspaceInputDevices,
            inputCameraDeviceMappings: inputCameraDeviceMappings
        )
        return ProgramPreviewSnapshot(
            definition: definition,
            composite: composite,
            audioChannels: workspaceAudioChannels,
            canvasWidth: outputCanvas.canvasSize.width,
            canvasHeight: outputCanvas.canvasSize.height,
            outputWidth: size.width,
            outputHeight: size.height,
            frameRate: previewFrameRate,
            timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
            programVideoPTSInputKey: programVideoPTSInputKey(
                for: definition,
                composite: composite,
                cameraIDsByInputKey: cameraIDsByInputKey
            ),
            programAudioDriverKey: programAudioDriverKey(
                for: definition,
                composite: composite,
                audioChannels: workspaceAudioChannels
            ),
            cameraIDsByInputKey: cameraIDsByInputKey,
            cameraInputColorOverrides: inputCameraColorRangeOverrides(
                for: definition,
                composite: composite,
                workspaceInputDevices: workspaceInputDevices
            ),
            backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
                for: definition,
                composite: composite,
                workspaceInputDevices: workspaceInputDevices
            )
        )
    }
}

#if DEBUG
#Preview("Program Preview") {
    @Previewable @State var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @Previewable @State var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()

    ProgramPreviewPane(
        outputCanvas: outputCanvas,
        outputDestination: outputDestination,
        workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
        selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
        compositeProgramDefinition: LDTXAppUIPreviewFixtures.compositeProgramDefinition,
        workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
        workspaceAudioChannels: LDTXAppUIPreviewFixtures.workspaceAudioChannels,
        inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings
    )
    .padding()
    .frame(width: 560, height: 380)
}
#endif

private struct ProgramPixelBufferPreview: NSViewRepresentable {
    var controller: ProgramPreviewController
    var frameRate: Int
    var mode: ProgramPixelBufferPreviewMode
    var taskPriority: TaskPriority = .userInitiated

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, mode: mode)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = ProgramPreviewMTKView(frame: .zero, device: context.coordinator.device)
        controller.start()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.previewDrawableScale = mode.drawableScale
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = max(frameRate, 1)
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.updateMode(mode)
        if let previewView = nsView as? ProgramPreviewMTKView {
            previewView.previewDrawableScale = mode.drawableScale
        }
        nsView.preferredFramesPerSecond = max(frameRate, 1)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.controller.stop()
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var controller: ProgramPreviewController
        private var mode: ProgramPixelBufferPreviewMode
        private let commandQueue: MTLCommandQueue?
        private let textureCache: CVMetalTextureCache?
        private let previewPipeline: MTLComputePipelineState?
        private let grayscalePreviewPipeline: MTLComputePipelineState?
        private var cachedFrameID: UInt64?
        private var cachedPixelBufferIdentity: UnsafeRawPointer?
        private var cachedLumaMetalTexture: CVMetalTexture?
        private var cachedChromaMetalTexture: CVMetalTexture?

        init(controller: ProgramPreviewController, mode: ProgramPixelBufferPreviewMode) {
            self.controller = controller
            self.mode = mode
            commandQueue = device?.makeCommandQueue()
            if let device {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
                previewPipeline = try? VideoCompositor.makePreviewNV12ToBGRAPipeline(device: device)
                grayscalePreviewPipeline = try? VideoCompositor.makePreviewLumaToGrayscaleBGRAPipeline(device: device)
            } else {
                textureCache = nil
                previewPipeline = nil
                grayscalePreviewPipeline = nil
            }
        }

        func updateMode(_ mode: ProgramPixelBufferPreviewMode) {
            if self.mode != mode {
                self.mode = mode
                clearCachedTextures()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  drawable.texture.width > 0,
                  drawable.texture.height > 0 else {
                return
            }

            guard let frame = controller.latestFrame() else {
                drawBlack(drawable: drawable, commandBuffer: commandBuffer)
                return
            }
            if frame.isPreparingRenderResources {
                drawGray(drawable: drawable, commandBuffer: commandBuffer)
                return
            }

            switch mode {
            case .color:
                drawColor(frame: frame, drawable: drawable, commandBuffer: commandBuffer)
            case .lightweight:
                drawLightweight(frame: frame, drawable: drawable, commandBuffer: commandBuffer)
            }
        }

        private func drawColor(
            frame: ProgramFrame,
            drawable: CAMetalDrawable,
            commandBuffer: MTLCommandBuffer
        ) {
            guard let pipeline = previewPipeline,
                  let sourceLuma = lumaTexture(for: frame),
                  let sourceChroma = chromaTexture(for: frame),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                drawBlack(drawable: drawable, commandBuffer: commandBuffer)
                return
            }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceLuma, index: 0)
            encoder.setTexture(sourceChroma, index: 1)
            encoder.setTexture(drawable.texture, index: 2)
            dispatch(encoder: encoder, pipeline: pipeline, width: drawable.texture.width, height: drawable.texture.height)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func drawLightweight(
            frame: ProgramFrame,
            drawable: CAMetalDrawable,
            commandBuffer: MTLCommandBuffer
        ) {
            guard let pipeline = grayscalePreviewPipeline,
                  let sourceLuma = lumaTexture(for: frame),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                drawBlack(drawable: drawable, commandBuffer: commandBuffer)
                return
            }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceLuma, index: 0)
            encoder.setTexture(drawable.texture, index: 1)
            dispatch(encoder: encoder, pipeline: pipeline, width: drawable.texture.width, height: drawable.texture.height)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func lumaTexture(for frame: ProgramFrame) -> MTLTexture? {
            prepareCache(for: frame)
            if cachedLumaMetalTexture == nil,
               let textureCache {
                cachedLumaMetalTexture = frame.makeCVMetalTexture(
                    using: textureCache,
                    pixelFormat: .r8Uint,
                    planeIndex: 0
                )
            }
            guard let cachedLumaMetalTexture else {
                return nil
            }
            return CVMetalTextureGetTexture(cachedLumaMetalTexture)
        }

        private func chromaTexture(for frame: ProgramFrame) -> MTLTexture? {
            prepareCache(for: frame)
            if cachedChromaMetalTexture == nil,
               let textureCache {
                cachedChromaMetalTexture = frame.makeCVMetalTexture(
                    using: textureCache,
                    pixelFormat: .rg8Uint,
                    planeIndex: 1
                )
            }
            guard let cachedChromaMetalTexture else {
                return nil
            }
            return CVMetalTextureGetTexture(cachedChromaMetalTexture)
        }

        private func prepareCache(for frame: ProgramFrame) {
            let pixelBufferIdentity = Self.pixelBufferIdentity(frame.pixelBuffer)
            if cachedFrameID != frame.frameID ||
                cachedPixelBufferIdentity != pixelBufferIdentity {
                clearCachedTextures()
                cachedFrameID = frame.frameID
                cachedPixelBufferIdentity = pixelBufferIdentity
            }
        }

        private func clearCachedTextures() {
            cachedFrameID = nil
            cachedPixelBufferIdentity = nil
            cachedLumaMetalTexture = nil
            cachedChromaMetalTexture = nil
        }

        private static func pixelBufferIdentity(_ pixelBuffer: CVPixelBuffer) -> UnsafeRawPointer {
            UnsafeRawPointer(Unmanaged.passUnretained(pixelBuffer).toOpaque())
        }

        private func dispatch(
            encoder: MTLComputeCommandEncoder,
            pipeline: MTLComputePipelineState,
            width: Int,
            height: Int
        ) {
            let threadgroupWidth = pipeline.threadExecutionWidth
            let threadgroupHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadgroupWidth)
            let threadsPerThreadgroup = MTLSize(width: threadgroupWidth, height: threadgroupHeight, depth: 1)
            let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        private func drawBlack(
            drawable: CAMetalDrawable,
            commandBuffer: MTLCommandBuffer
        ) {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func drawGray(
            drawable: CAMetalDrawable,
            commandBuffer: MTLCommandBuffer
        ) {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.28, 0.28, 0.28, 1)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

private final class ProgramPreviewMTKView: MTKView {
    var previewDrawableScale: CGFloat = 1 {
        didSet {
            if previewDrawableScale != oldValue {
                updateScaledDrawableSize()
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScaledDrawableSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateScaledDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaledDrawableSize()
    }

    override func layout() {
        super.layout()
        updateScaledDrawableSize()
    }

    private func updateScaledDrawableSize() {
        let backingBounds = convertToBacking(bounds)
        let scale = max(previewDrawableScale, 1)
        let width = max(1, Int((backingBounds.width / scale).rounded()))
        let height = max(1, Int((backingBounds.height / scale).rounded()))
        let nextDrawableSize = CGSize(width: width, height: height)
        if drawableSize != nextDrawableSize {
            drawableSize = nextDrawableSize
        }
    }
}

private enum ProgramPixelBufferPreviewMode: Hashable {
    case color
    case lightweight

    var drawableScale: CGFloat {
        switch self {
        case .color:
            1
        case .lightweight:
            1
        }
    }
}
