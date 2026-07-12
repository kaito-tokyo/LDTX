// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import LDTXCapture
import LDTXDash
import LDTXProgramRendering
import LDTXProgram
import LDTXProgramRuntime
import LDTXSupport
import LDTXVideoComposition
import LDTXVideoRendering
import LDTXYouTube
import Metal
import UniformTypeIdentifiers

struct ProgramRenderCommand {
    private let options: [String: String]
    private let positionalArguments: [String]

    init(options: [String: String], flags _: Set<String>, positionalArguments: [String]) {
        self.options = options
        self.positionalArguments = positionalArguments
    }

    static func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        let failureReason = nsError.localizedFailureReason.map { " failureReason=\($0)" } ?? ""
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            " underlying=\($0.domain)(\($0.code)): \($0.localizedDescription)"
        } ?? ""
        return "\(error.localizedDescription)\(failureReason)\(underlying)"
    }

    func run() async throws {
        let inputData = try inputProgramData()
        let output = try outputImageDestination()
        let startTimeSeconds = options["--time-seconds"].flatMap(Float.init) ?? 0
        let frameCount = try frameCountOption()

        let program = try JSONDecoder().decode(RenderProgramDefinition.self, from: inputData)
        try program.validate()
        try output.validate(frameCount: frameCount)
        let composite = CompositeProgramDefinition(steps: program.videoComponents.map(\.step))
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw VideoCompositorError.metalDeviceUnavailable
        }

        let cameraFrameProvider = try await makeCameraFrameProvider(
            composite: composite,
            width: program.canvas.width,
            height: program.canvas.height,
            frameRate: program.canvas.frameRate.numerator,
            metalDevice: metalDevice
        )

        do {
            let compositor = try VideoCompositor(
                configuration: VideoCompositorConfiguration(
                    width: program.canvas.width,
                    height: program.canvas.height,
                    pixelBufferPoolMinimumBufferCount: 3
                ),
                device: metalDevice
            )
            for frameIndex in 0..<frameCount {
                let timeSeconds = startTimeSeconds + program.canvas.frameRate.secondsPerFrame * Float(frameIndex)
                let sourcesByInputKey = try cameraFrameProvider?.makeSourcesByInputKey() ?? [:]
                let components = ProgramDefinition.composite.components(
                    width: program.canvas.width,
                    height: program.canvas.height,
                    composite: composite,
                    sourcesByInputKey: sourcesByInputKey,
                    timeSeconds: timeSeconds
                )
                let pixelBuffer = try compositor.render(components)
                let imageData = try makeImageData(pixelBuffer: pixelBuffer, format: output.format)
                try output.write(imageData, frameIndex: frameIndex, frameCount: frameCount)
            }
        } catch {
            await cameraFrameProvider?.stop()
            throw error
        }
        await cameraFrameProvider?.stop()
    }

    private func makeCameraFrameProvider(
        composite: CompositeProgramDefinition,
        width: Int,
        height: Int,
        frameRate: Int,
        metalDevice: MTLDevice
    ) async throws -> ProgramRenderCameraFrameProvider? {
        let cameraMappings = inputCameraMappings()
        guard !cameraMappings.isEmpty else {
            return nil
        }

        let provider = try ProgramRenderCameraFrameProvider(
            width: width,
            height: height,
            frameRate: frameRate,
            metalDevice: metalDevice
        )

        for step in composite.steps {
            guard case let .inputCameraDevice(payload) = step.component else {
                continue
            }
            let inputKey = composite.inputCameraDeviceMappingKey(for: step)
            guard let cameraQuery = cameraMappings[inputKey] else {
                continue
            }
            let camera = try selectedCamera(matching: cameraQuery)
            provider.addMapping(
                inputKey: inputKey,
                camera: camera
            )
        }

        try await provider.start()
        return provider
    }

    private func inputCameraMappings() -> [String: String] {
        var mappings: [String: String] = [:]
        for key in ["--input-camera", "--input-mapping"] {
            if let value = options[key] {
                for pair in value.split(separator: ",") {
                    guard let equalsIndex = pair.firstIndex(of: "=") else {
                        continue
                    }
                    let inputKey = pair[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    let cameraQuery = pair[pair.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inputKey.isEmpty, !cameraQuery.isEmpty {
                        mappings[inputKey] = cameraQuery
                    }
                }
            }
        }

        let prefix = "--input-camera-"
        for (key, value) in options where key.hasPrefix(prefix) {
            let inputKey = String(key.dropFirst(prefix.count))
            if !inputKey.isEmpty {
                mappings[inputKey] = value
            }
        }
        return mappings
    }

    private func selectedCamera(matching query: String) throws -> CameraCaptureSource {
        let cameras = CameraCaptureService().availableCameras()
        if let camera = cameras.first(where: { $0.id == query }) {
            return camera
        }
        let normalizedQuery = query.localizedLowercase
        if let camera = cameras.first(where: { $0.name.localizedLowercase == normalizedQuery }) {
            return camera
        }
        if let camera = cameras.first(where: { $0.name.localizedLowercase.contains(normalizedQuery) }) {
            return camera
        }
        throw ProgramRenderCommandError.cameraNotFound(query)
    }

    private func inputProgramData() throws -> Data {
        guard let path = options["--program-json"] ?? options["--input"] ?? positionalArguments.first else {
            throw ProgramRenderCommandError.missingProgramJSON
        }
        if path == "-" {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        return try Data(contentsOf: URL(fileURLWithPath: expandedPath(path)))
    }

    private func frameCountOption() throws -> Int {
        guard let value = options["--frame-count"] else {
            return 1
        }
        guard let frameCount = Int(value), frameCount > 0 else {
            throw ProgramRenderCommandError.invalidFrameCount(value)
        }
        return frameCount
    }

    private func outputImageDestination() throws -> ProgramRenderOutput {
        guard let path = options["--output"] ?? positionalArguments.dropFirst().first else {
            throw ProgramRenderCommandError.missingOutput
        }
        if path == "-" {
            return .standardOutput(try outputFormatOption() ?? .png)
        }
        let url = try outputURL(for: path)
        let format = try outputFormatOption() ?? ProgramRenderImageFormat(pathExtension: url.pathExtension)
        guard let format else {
            throw ProgramRenderCommandError.unsupportedOutputExtension(url.pathExtension)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return .file(url, format)
    }

    private func outputFormatOption() throws -> ProgramRenderImageFormat? {
        guard let value = options["--output-format"] else {
            return nil
        }
        guard let format = ProgramRenderImageFormat(name: value) else {
            throw ProgramRenderCommandError.unsupportedOutputFormat(value)
        }
        return format
    }

    private func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func outputURL(for path: String) throws -> URL {
        let expanded = expandedPath(path)
        if expanded == (expanded as NSString).lastPathComponent {
            return try sandboxMoviesDirectory().appendingPathComponent(expanded, isDirectory: false)
        }
        return URL(fileURLWithPath: expanded)
    }

    private func sandboxMoviesDirectory() throws -> URL {
        guard let moviesDirectory = FileManager.default.urls(
            for: .moviesDirectory,
            in: .userDomainMask
        ).first else {
            throw ProgramRenderCommandError.moviesDirectoryUnavailable
        }
        try FileManager.default.createDirectory(at: moviesDirectory, withIntermediateDirectories: true)
        return moviesDirectory
    }

    private func makeImageData(pixelBuffer: CVPixelBuffer, format: ProgramRenderImageFormat) throws -> Data {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull()
        ])
        let extent = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let cgImage = context.createCGImage(ciImage, from: extent) else {
            throw ProgramRenderCommandError.imageCreationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.uniformTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ProgramRenderCommandError.imageDestinationCreationFailed
        }
        CGImageDestinationAddImage(destination, cgImage, format.properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProgramRenderCommandError.imageEncodingFailed
        }
        return data as Data
    }

    static func copyPixelBuffer(_ source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(destination) else {
                return
            }
            copyRows(
                sourceBaseAddress: sourceBaseAddress,
                destinationBaseAddress: destinationBaseAddress,
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                bytesPerRow: min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination)),
                height: CVPixelBufferGetHeight(source)
            )
            return
        }

        for planeIndex in 0..<planeCount {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(source, planeIndex),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destination, planeIndex) else {
                continue
            }
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, planeIndex)
            copyRows(
                sourceBaseAddress: sourceBaseAddress,
                destinationBaseAddress: destinationBaseAddress,
                sourceBytesPerRow: sourceBytesPerRow,
                destinationBytesPerRow: destinationBytesPerRow,
                bytesPerRow: min(sourceBytesPerRow, destinationBytesPerRow),
                height: CVPixelBufferGetHeightOfPlane(source, planeIndex)
            )
        }
    }

    private static func copyRows(
        sourceBaseAddress: UnsafeMutableRawPointer,
        destinationBaseAddress: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        destinationBytesPerRow: Int,
        bytesPerRow: Int,
        height: Int
    ) {
        for y in 0..<height {
            memcpy(
                destinationBaseAddress.advanced(by: y * destinationBytesPerRow),
                sourceBaseAddress.advanced(by: y * sourceBytesPerRow),
                bytesPerRow
            )
        }
    }
}

private struct CapturedPixelBuffer {
    var serial: UInt64
    var pixelBuffer: CVPixelBuffer
}

/// Owns a copied pixel-buffer ring. All mutable state is protected by
/// `condition`; capture callbacks never retain their source buffers.
private final class ProgramRenderCameraFrameStore: @unchecked Sendable {
    private static let pixelBufferRingCount = 3

    private let condition = NSCondition()
    private var capturedPixelBuffer: CapturedPixelBuffer?
    private var latestSerial: UInt64 = 0
    private var pixelBuffers: [CVPixelBuffer]
    private var nextPixelBufferIndex = 0

    init(width: Int, height: Int) throws {
        pixelBuffers = try Self.makePixelBuffers(width: width, height: height)
    }

    func wait(after serial: UInt64? = nil, timeout: TimeInterval) -> CapturedPixelBuffer? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while capturedPixelBuffer == nil || (serial != nil && capturedPixelBuffer!.serial <= serial!) {
            guard condition.wait(until: deadline) else {
                return nil
            }
        }
        return capturedPixelBuffer
    }

    func copyAndYield(_ sourcePixelBuffer: CVPixelBuffer) {
        condition.lock()
        defer { condition.unlock() }
        guard CVPixelBufferGetPixelFormatType(sourcePixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(sourcePixelBuffer) == CVPixelBufferGetWidth(pixelBuffers[nextPixelBufferIndex]),
              CVPixelBufferGetHeight(sourcePixelBuffer) == CVPixelBufferGetHeight(pixelBuffers[nextPixelBufferIndex]) else {
            return
        }
        let pixelBuffer = pixelBuffers[nextPixelBufferIndex]
        nextPixelBufferIndex = (nextPixelBufferIndex + 1) % pixelBuffers.count
        ProgramRenderCommand.copyPixelBuffer(sourcePixelBuffer, to: pixelBuffer)
        latestSerial &+= 1
        capturedPixelBuffer = CapturedPixelBuffer(serial: latestSerial, pixelBuffer: pixelBuffer)
        condition.broadcast()
    }

    private static func makePixelBuffers(width: Int, height: Int) throws -> [CVPixelBuffer] {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: pixelBufferRingCount
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pixelBufferPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )
        guard poolStatus == kCVReturnSuccess, let pixelBufferPool else {
            throw ProgramRenderCommandError.pixelBufferCreationFailed(poolStatus)
        }

        return try (0..<pixelBufferRingCount).map { _ in
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw ProgramRenderCommandError.pixelBufferCreationFailed(status)
            }
            return pixelBuffer
        }
    }
}

private final class ProgramRenderCameraFrameProvider {
    private struct InputMapping {
        var inputKey: String
        var camera: CameraCaptureSource
    }

    private let width: Int
    private let height: Int
    private let frameRate: Int
    private let sourceFactory: ProgramRenderMetalSourceFactory
    private var mappings: [InputMapping] = []
    private var storesByCameraID: [String: ProgramRenderCameraFrameStore] = [:]
    private var captureServicesByCameraID: [String: CameraCaptureService] = [:]
    private var consumedSerialByCameraID: [String: UInt64] = [:]

    init(width: Int, height: Int, frameRate: Int, metalDevice: MTLDevice) throws {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        sourceFactory = try ProgramRenderMetalSourceFactory(metalDevice: metalDevice)
    }

    func addMapping(inputKey: String, camera: CameraCaptureSource) {
        mappings.append(InputMapping(
            inputKey: inputKey,
            camera: camera
        ))
    }

    func start() async throws {
        let uniqueCameras = Dictionary(grouping: mappings, by: { $0.camera.id }).compactMap { $0.value.first?.camera }
        for camera in uniqueCameras {
            let store = try ProgramRenderCameraFrameStore(width: width, height: height)
            let captureService = CameraCaptureService()
            storesByCameraID[camera.id] = store
            captureServicesByCameraID[camera.id] = captureService
            try await withCheckedThrowingContinuation { continuation in
                captureService.startCameraCapture(
                    cameraID: camera.id,
                    targetWidth: width,
                    targetHeight: height,
                    frameRate: frameRate,
                    capturesAudio: false,
                    handler: { sampleBuffer, kind in
                        guard kind == .video,
                              let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            return
                        }
                        store.copyAndYield(sourcePixelBuffer)
                    },
                    completionHandler: { result in
                        continuation.resume(with: result)
                    }
                )
            }
            _ = try waitForFrame(camera: camera)
        }
    }

    func stop() async {
        let captureServices = Array(captureServicesByCameraID.values)
        captureServicesByCameraID = [:]
        storesByCameraID = [:]
        consumedSerialByCameraID = [:]
        for captureService in captureServices {
            await withCheckedContinuation { continuation in
                captureService.stop {
                    continuation.resume()
                }
            }
        }
    }

    func makeSourcesByInputKey() throws -> [String: MetalVideoSource] {
        var sourcesByInputKey: [String: MetalVideoSource] = [:]
        var pixelBuffersByCameraID: [String: CVPixelBuffer] = [:]
        var sourcesByCameraID: [String: MetalVideoSource] = [:]
        for mapping in mappings {
            let sourcePixelBuffer: CVPixelBuffer
            if let cached = pixelBuffersByCameraID[mapping.camera.id] {
                sourcePixelBuffer = cached
            } else {
                let frame = try waitForFrame(camera: mapping.camera)
                consumedSerialByCameraID[mapping.camera.id] = frame.serial
                sourcePixelBuffer = frame.pixelBuffer
                pixelBuffersByCameraID[mapping.camera.id] = sourcePixelBuffer
            }

            if let source = sourcesByCameraID[mapping.camera.id] {
                sourcesByInputKey[mapping.inputKey] = source
            } else {
                let source = try sourceFactory.source(pixelBuffer: sourcePixelBuffer)
                sourcesByCameraID[mapping.camera.id] = source
                sourcesByInputKey[mapping.inputKey] = source
            }
        }
        return sourcesByInputKey
    }

    private func waitForFrame(camera: CameraCaptureSource) throws -> CapturedPixelBuffer {
        guard let store = storesByCameraID[camera.id] else {
            throw ProgramRenderCommandError.cameraNotFound(camera.name)
        }
        guard let frame = store.wait(
            after: consumedSerialByCameraID[camera.id],
            timeout: 5
        ) else {
            throw ProgramRenderCommandError.cameraFrameTimedOut(camera.name)
        }
        return frame
    }

}

private final class ProgramRenderMetalSourceFactory {
    private let textureCache: CVMetalTextureCache

    init(metalDevice: MTLDevice) throws {
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache)
        guard let textureCache else {
            throw VideoCompositorError.metalDeviceUnavailable
        }
        self.textureCache = textureCache
    }

    func source(pixelBuffer: CVPixelBuffer) throws -> MetalVideoSource {
        let lumaMetalTexture = try makeTexture(
            pixelBuffer,
            pixelFormat: .r8Uint,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            planeIndex: 0
        )
        let chromaMetalTexture = try makeTexture(
            pixelBuffer,
            pixelFormat: .rg8Uint,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            planeIndex: 1
        )
        return .nv12Textures(
            pixelBuffer: pixelBuffer,
            lumaMetalTexture: lumaMetalTexture,
            chromaMetalTexture: chromaMetalTexture,
            alphaTexture: nil,
            alphaMaskKind: nil
        )
    }

    private func makeTexture(
        _ pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> CVMetalTexture {
        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &metalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture else {
            throw VideoCompositorError.textureCreationFailed(status)
        }
        return metalTexture
    }
}

private enum ProgramRenderOutput {
    case file(URL, ProgramRenderImageFormat)
    case standardOutput(ProgramRenderImageFormat)

    var format: ProgramRenderImageFormat {
        switch self {
        case let .file(_, format), let .standardOutput(format):
            format
        }
    }

    func validate(frameCount: Int) throws {
        if case .standardOutput = self, frameCount > 1 {
            throw ProgramRenderCommandError.multipleFramesRequireFileOutput
        }
    }

    func write(_ data: Data, frameIndex: Int, frameCount: Int) throws {
        switch self {
        case let .file(url, _):
            let outputURL = frameCount == 1 ? url : numberedURL(baseURL: url, frameIndex: frameIndex)
            do {
                try data.write(to: outputURL)
            } catch {
                throw ProgramRenderCommandError.fileWriteFailed(outputURL.path, error)
            }
            print(outputURL.path)
        case .standardOutput:
            FileHandle.standardOutput.write(data)
        }
    }

    private func numberedURL(baseURL: URL, frameIndex: Int) -> URL {
        let directory = baseURL.deletingLastPathComponent()
        let pathExtension = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let numberedName = "\(stem)-\(String(format: "%06d", frameIndex + 1)).\(pathExtension)"
        return directory.appendingPathComponent(numberedName, isDirectory: false)
    }
}

private enum ProgramRenderImageFormat {
    case png
    case jpeg

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "png":
            self = .png
        case "jpg", "jpeg":
            self = .jpeg
        default:
            return nil
        }
    }

    init?(name: String) {
        switch name.lowercased() {
        case "png":
            self = .png
        case "jpg", "jpeg":
            self = .jpeg
        default:
            return nil
        }
    }

    var uniformTypeIdentifier: String {
        switch self {
        case .png:
            UTType.png.identifier
        case .jpeg:
            UTType.jpeg.identifier
        }
    }

    var properties: [CFString: Any] {
        switch self {
        case .png:
            [:]
        case .jpeg:
            [kCGImageDestinationLossyCompressionQuality: 0.92]
        }
    }
}

private enum ProgramRenderCommandError: LocalizedError {
    case missingProgramJSON
    case missingOutput
    case missingName
    case invalidCanvasSize
    case invalidFrameCount(String)
    case multipleFramesRequireFileOutput
    case moviesDirectoryUnavailable
    case cameraNotFound(String)
    case cameraFrameTimedOut(String)
    case pixelBufferCreationFailed(CVReturn)
    case backgroundRemovalFailed
    case unsupportedOutputExtension(String)
    case unsupportedOutputFormat(String)
    case imageDestinationCreationFailed
    case imageCreationFailed
    case fileWriteFailed(String, Error)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingProgramJSON:
            "Specify Program Definition JSON with --program-json <path> or --input <path>."
        case .missingOutput:
            "Specify the output image with --output <path.png|path.jpg>."
        case .missingName:
            "Program Definition JSON must include a non-empty name."
        case .invalidCanvasSize:
            "Program Definition JSON must include a positive canvas width and height."
        case let .invalidFrameCount(value):
            "--frame-count must be a positive integer. Invalid value: \(value)."
        case .multipleFramesRequireFileOutput:
            "Multiple frame output requires a file path; --output - can only write one image."
        case .moviesDirectoryUnavailable:
            "The Movies directory could not be located."
        case let .cameraNotFound(query):
            "No camera matched input mapping value: \(query)."
        case let .cameraFrameTimedOut(name):
            "Timed out waiting for a video frame from camera: \(name)."
        case let .pixelBufferCreationFailed(status):
            "CVPixelBufferCreate failed with status \(status)."
        case .backgroundRemovalFailed:
            "Background removal failed."
        case let .unsupportedOutputExtension(value):
            "Only PNG and JPEG output are supported. Unsupported extension: \(value.isEmpty ? "(none)" : value)."
        case let .unsupportedOutputFormat(value):
            "Only png and jpeg output formats are supported. Unsupported format: \(value)."
        case .imageDestinationCreationFailed:
            "The image destination could not be created."
        case .imageCreationFailed:
            "The rendered pixel buffer could not be converted to an image."
        case let .fileWriteFailed(path, error):
            "The rendered image could not be written to \(path): \(error.localizedDescription)"
        case .imageEncodingFailed:
            "The image could not be encoded."
        }
    }
}

private struct RenderProgramDefinition: Decodable {
    var schema: String?
    var name: String
    var canvas: RenderProgramCanvas
    var videoComponents: [RenderProgramStep]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case name
        case canvas
        case videoComponents
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProgramRenderCommandError.missingName
        }
        guard canvas.width > 0, canvas.height > 0 else {
            throw ProgramRenderCommandError.invalidCanvasSize
        }
    }
}

private struct RenderProgramCanvas: Decodable {
    var width: Int
    var height: Int
    var frameRate: RenderProgramFrameRate
}

private struct RenderProgramFrameRate: Decodable {
    var numerator: Int
    var denominator: Int

    var secondsPerFrame: Float {
        guard numerator > 0, denominator > 0 else {
            return 1.0 / 60.0
        }
        return Float(denominator) / Float(numerator)
    }
}

private struct RenderProgramStep: Decodable {
    private var component: ProgramComponent

    var step: CompositeProgramStep {
        CompositeProgramStep(component: component)
    }

    init(from decoder: Decoder) throws {
        component = try ProgramComponent(from: decoder)
    }
}
