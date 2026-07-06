// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime
import MetalKit
import OSLog
import simd

private let audioInputSpectrogramViewLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "AudioInputSpectrogramView"
)

final class AudioInputSpectrogramMTKView: MTKView, MTKViewDelegate {
    private final class SharedMetalResources {
        let device: MTLDevice?
        let commandQueue: MTLCommandQueue?
        let pipelineState: MTLRenderPipelineState?
        let samplerState: MTLSamplerState?

        init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            if let device {
                self.pipelineState = AudioInputSpectrogramMTKView.makePipelineState(
                    device: device,
                    pixelFormat: .bgra8Unorm
                )
                self.samplerState = AudioInputSpectrogramMTKView.makeSamplerState(device: device)
            } else {
                self.pipelineState = nil
                self.samplerState = nil
            }
        }
    }

    private static let quadVertices: [Float] = [
        -1, -1, 0, 1,
         1, -1, 1, 1,
        -1,  1, 0, 0,
         1, -1, 1, 1,
         1,  1, 1, 0,
        -1,  1, 0, 0
    ]
    private static let sharedMetalResources = SharedMetalResources()

    var snapshot = InputAudioSpectrogramSnapshot.empty {
        didSet {
            updateTexture()
            if Thread.isMainThread {
                draw()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.draw()
                }
            }
        }
    }

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var spectrogramTexture: MTLTexture?
    private var hasLoggedDrawSuccess = false
    private var hasLoggedDrawFailure = false

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let metalDevice = device ?? Self.sharedMetalResources.device
        super.init(frame: frameRect, device: metalDevice)
        commonInit()
    }

    convenience init() {
        self.init(frame: .zero, device: Self.sharedMetalResources.device)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = Self.sharedMetalResources.device
        commonInit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if !hasLoggedDrawFailure {
            if device == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: device is nil")
            } else if commandQueue == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: commandQueue is nil")
            } else if pipelineState == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: pipelineState is nil")
            } else if samplerState == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: samplerState is nil")
            } else if spectrogramTexture == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: texture is nil")
            } else if currentRenderPassDescriptor == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: renderPassDescriptor is nil")
            } else if currentDrawable == nil {
                hasLoggedDrawFailure = true
                audioInputSpectrogramViewLogger.error("Spectrogram draw skipped: currentDrawable is nil")
            }
        }
        guard let commandQueue,
              let pipelineState,
              let samplerState,
              let texture = spectrogramTexture,
              let passDescriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        if !hasLoggedDrawSuccess {
            hasLoggedDrawSuccess = true
            audioInputSpectrogramViewLogger.notice(
                "Spectrogram draw succeeded: texture=\(texture.width, privacy: .public)x\(texture.height, privacy: .public)"
            )
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        Self.quadVertices.withUnsafeBytes { buffer in
            encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.quadVertices.count / 4)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func commonInit() {
        guard let device else {
            isHidden = true
            return
        }

        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.03, 0.04, 0.06, 1)
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 15
        commandQueue = Self.sharedMetalResources.commandQueue ?? device.makeCommandQueue()
        pipelineState = Self.sharedMetalResources.pipelineState ??
            Self.makePipelineState(device: device, pixelFormat: colorPixelFormat)
        samplerState = Self.sharedMetalResources.samplerState ??
            Self.makeSamplerState(device: device)
        delegate = self
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        updateTexture()
        audioInputSpectrogramViewLogger.notice(
            "Spectrogram view initialized: device=\(device.name, privacy: .public), pipelineReady=\(self.pipelineState != nil, privacy: .public)"
        )
    }

    private func updateTexture() {
        guard let device else {
            spectrogramTexture = nil
            return
        }

        let width = max(snapshot.columnCapacity, 1)
        let height = max(snapshot.binCount, 1)
        if spectrogramTexture?.width != width || spectrogramTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            spectrogramTexture = device.makeTexture(descriptor: descriptor)
        }

        guard let spectrogramTexture else {
            return
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        fillBackground(into: &pixels, width: width, height: height)
        renderSpectrogramColumns(into: &pixels, width: width, height: height)

        pixels.withUnsafeBytes { buffer in
            spectrogramTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * 4
            )
        }
    }

    private func fillBackground(into pixels: inout [UInt8], width: Int, height: Int) {
        let lineRows = Set([
            Int(Float(height - 1) * 0.25),
            Int(Float(height - 1) * 0.5),
            Int(Float(height - 1) * 0.75)
        ])

        for y in 0..<height {
            let vertical = Float(y) / Float(max(height - 1, 1))
            let top = SIMD3<Float>(0.03, 0.04, 0.06)
            let bottom = SIMD3<Float>(0.0, 0.0, 0.0)
            var color = top + (bottom - top) * vertical
            if lineRows.contains(y) {
                color += SIMD3<Float>(repeating: 0.08)
            }
            let clamped = simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            for x in 0..<width {
                write(color: clamped, alpha: 1, x: x, y: y, width: width, into: &pixels)
            }
        }
    }

    private func renderSpectrogramColumns(into pixels: inout [UInt8], width: Int, height: Int) {
        let columns = snapshot.columns
        guard !columns.isEmpty else {
            return
        }

        let xOffset = max(width - columns.count, 0)
        for (columnIndex, column) in columns.enumerated() {
            let x = xOffset + columnIndex
            guard x < width else {
                continue
            }
            for (binIndex, intensity) in column.enumerated() where binIndex < height {
                let y = height - binIndex - 1
                let color = spectrogramColor(for: intensity)
                write(color: color, alpha: 1, x: x, y: y, width: width, into: &pixels)
            }
        }
    }

    private func spectrogramColor(for intensity: Float) -> SIMD3<Float> {
        let t = max(0, min(1, intensity))
        let stops: [(position: Float, color: SIMD3<Float>)] = [
            (0.0, SIMD3(0.02, 0.03, 0.08)),
            (0.22, SIMD3(0.05, 0.18, 0.46)),
            (0.45, SIMD3(0.05, 0.64, 0.72)),
            (0.68, SIMD3(0.86, 0.77, 0.19)),
            (1.0, SIMD3(0.98, 0.35, 0.18))
        ]

        for index in 0..<(stops.count - 1) {
            let current = stops[index]
            let next = stops[index + 1]
            guard t >= current.position, t <= next.position else {
                continue
            }
            let unit = (t - current.position) / max(next.position - current.position, 0.000_1)
            return current.color + (next.color - current.color) * unit
        }

        return stops.last?.color ?? SIMD3<Float>(repeating: 1)
    }

    private func write(
        color: SIMD3<Float>,
        alpha: Float,
        x: Int,
        y: Int,
        width: Int,
        into pixels: inout [UInt8]
    ) {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8(max(0, min(255, Int(color.x * 255))))
        pixels[offset + 1] = UInt8(max(0, min(255, Int(color.y * 255))))
        pixels[offset + 2] = UInt8(max(0, min(255, Int(color.z * 255))))
        pixels[offset + 3] = UInt8(max(0, min(255, Int(alpha * 255))))
    }

    private static func makePipelineState(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        do {
            guard let library = makeShaderLibrary(device: device) else {
                audioInputSpectrogramViewLogger.error("Spectrogram shader library was not found")
                return nil
            }
            guard let vertexFunction = library.makeFunction(name: "audio_input_spectrogram_vertex"),
                  let fragmentFunction = library.makeFunction(name: "audio_input_spectrogram_fragment") else {
                audioInputSpectrogramViewLogger.error("Spectrogram shader functions were not found in library")
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            audioInputSpectrogramViewLogger.error(
                "Failed to create spectrogram pipeline state: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func makeShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        if let library = try? device.makeDefaultLibrary(bundle: Bundle(for: AudioInputSpectrogramMTKView.self)) {
            return library
        }
        return device.makeDefaultLibrary()
    }

    private static func makeSamplerState(device: MTLDevice) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
}
