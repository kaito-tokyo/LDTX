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
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var compositeProgramDefinition: CompositeProgramDefinition
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var inputCameraDeviceMappings: [String: String]
    @StateObject private var previewController: ProgramPreviewController

    init(
        title: String? = nil,
        outputCanvas: OutputCanvasModel,
        outputDestination: OutputDestinationModel,
        workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        compositeProgramDefinition: CompositeProgramDefinition,
        workspaceInputDevices: [WorkspaceInputDeviceRecord],
        inputCameraDeviceMappings: [String: String]
    ) {
        self.title = title
        self.outputCanvas = outputCanvas
        self.outputDestination = outputDestination
        self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.compositeProgramDefinition = compositeProgramDefinition
        self.workspaceInputDevices = workspaceInputDevices
        self.inputCameraDeviceMappings = inputCameraDeviceMappings
        _previewController = StateObject(
            wrappedValue: ProgramPreviewController(captureSessionCoordinator: workspaceCaptureSessionCoordinator)
        )
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
                    taskPriority: .utility
                )
            }
            .aspectRatio(Double(previewSize.width) / Double(previewSize.height), contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            configurePreview()
        }
        .onChange(of: outputDestination.selectedResolution) { _, _ in configurePreview() }
        .onChange(of: selectedProgramDefinitionRecord) { _, _ in configurePreview() }
        .onChange(of: compositeProgramDefinition) { _, _ in configurePreview() }
        .onChange(of: outputCanvas.state) { _, _ in configurePreview() }
        .onChange(of: workspaceInputDevices) { _, _ in configurePreview() }
        .onChange(of: inputCameraDeviceMappings) { _, _ in configurePreview() }
    }

    private var previewSize: (width: Int, height: Int) {
        captureTargetSize(for: outputDestination.selectedResolution)
    }

    private var previewFrameRate: Int {
        max(outputCanvas.programDefinitionFrameRate, 1)
    }

    private var previewStatus: String {
        "\(previewSize.width)x\(previewSize.height) @ \(previewFrameRate) fps"
    }

    @MainActor
    private func configurePreview() {
        let snapshot = previewSnapshot()
        previewController.configure(snapshot: snapshot)
    }

    @MainActor
    private func previewSnapshot() -> ProgramPreviewSnapshot {
        let size = previewSize
        let definition = ProgramDefinition.composite
        let composite = outputCanvas.applying(to: compositeProgramDefinition)
        return ProgramPreviewSnapshot(
            definition: definition,
            composite: composite,
            canvasWidth: programWorldCanvasSize.width,
            canvasHeight: programWorldCanvasSize.height,
            outputWidth: size.width,
            outputHeight: size.height,
            frameRate: previewFrameRate,
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
                workspaceInputDevices: workspaceInputDevices,
                inputCameraDeviceMappings: inputCameraDeviceMappings
            ),
            backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
                for: definition,
                composite: composite
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
        inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings
    )
    .padding()
    .frame(width: 560, height: 380)
}
#endif

private struct ProgramPixelBufferPreview: NSViewRepresentable {
    var controller: ProgramPreviewController
    var frameRate: Int
    var taskPriority: TaskPriority = .userInitiated

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        controller.start(priority: taskPriority)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = max(frameRate, 1)
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.controller = controller
        nsView.preferredFramesPerSecond = max(frameRate, 1)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.controller.stop()
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var controller: ProgramPreviewController
        private let commandQueue: MTLCommandQueue?
        private let textureCache: CVMetalTextureCache?
        private let previewPipeline: MTLComputePipelineState?

        init(controller: ProgramPreviewController) {
            self.controller = controller
            commandQueue = device?.makeCommandQueue()
            if let device {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
                previewPipeline = try? VideoCompositor.makePreviewNV12ToBGRAPipeline(device: device)
            } else {
                textureCache = nil
                previewPipeline = nil
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let pipeline = previewPipeline,
                  view.drawableSize.width > 0,
                  view.drawableSize.height > 0 else {
                return
            }

            guard let pixelBuffer = controller.latestPixelBuffer() else {
                drawBlack(drawable: drawable, commandBuffer: commandBuffer)
                return
            }
            if controller.isPreparingRenderResources() {
                drawGray(drawable: drawable, commandBuffer: commandBuffer)
                return
            }

            guard let sourceLuma = texture(
                from: pixelBuffer,
                pixelFormat: .r8Unorm,
                planeIndex: 0
            ),
                  let sourceChroma = texture(
                    from: pixelBuffer,
                    pixelFormat: .rg8Unorm,
                    planeIndex: 1
                  ),
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

        private func texture(
            from pixelBuffer: CVPixelBuffer,
            pixelFormat: MTLPixelFormat,
            planeIndex: Int
        ) -> MTLTexture? {
            guard let textureCache else {
                return nil
            }

            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
            var cvMetalTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                pixelFormat,
                width,
                height,
                planeIndex,
                &cvMetalTexture
            )
            guard status == kCVReturnSuccess,
                  let cvMetalTexture,
                  let texture = CVMetalTextureGetTexture(cvMetalTexture) else {
                return nil
            }
            return texture
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
