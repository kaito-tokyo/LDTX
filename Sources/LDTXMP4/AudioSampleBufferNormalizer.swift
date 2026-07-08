// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

public enum AudioSampleBufferNormalizerError: Error, LocalizedError {
    case missingFormatDescription
    case unsupportedInputFormat
    case bufferAllocationFailed
    case pcmCopyFailed(OSStatus)
    case conversionFailed(String)
    case blockBufferCreationFailed(OSStatus)
    case audioFormatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            "The audio sample buffer has no format description."
        case .unsupportedInputFormat:
            "The audio sample buffer format is not supported for 48 kHz normalization."
        case .bufferAllocationFailed:
            "The 48 kHz audio normalization buffer could not be allocated."
        case let .pcmCopyFailed(status):
            "The audio sample buffer PCM data could not be copied: \(status)."
        case let .conversionFailed(reason):
            "The audio sample buffer could not be converted to 48 kHz PCM: \(reason)."
        case let .blockBufferCreationFailed(status):
            "The normalized audio block buffer could not be created: \(status)."
        case let .audioFormatDescriptionCreationFailed(status):
            "The normalized audio format description could not be created: \(status)."
        case let .sampleBufferCreationFailed(status):
            "The normalized audio sample buffer could not be created: \(status)."
        }
    }
}

public final class AudioSampleBufferNormalizer: @unchecked Sendable {
    public static let sampleRate = 48_000
    public static let channelCount = 2

    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let outputFormatDescription: CMAudioFormatDescription
    private var converter: AVAudioConverter?
    private var inputFormatKey: InputFormatKey?
    private var inputBufferFormatKey: InputFormatKey?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?

    public init() throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: AVAudioChannelCount(Self.channelCount),
            interleaved: true
        ) else {
            throw AudioSampleBufferNormalizerError.unsupportedInputFormat
        }
        self.outputFormat = outputFormat
        outputFormatDescription = try Self.makeAudioFormatDescription(for: outputFormat)
    }

    public func normalize(_ sampleBuffer: CMSampleBuffer) throws -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return try normalizeOnLock(sampleBuffer)
    }

    public func withNormalizedFloat32Samples<Result>(
        _ sampleBuffer: CMSampleBuffer,
        _ body: (UnsafeBufferPointer<Float32>, Int) throws -> Result
    ) throws -> Result? {
        lock.lock()
        defer { lock.unlock() }

        guard let outputBuffer = try normalizePCMBufferOnLock(sampleBuffer) else {
            return nil
        }
        let frameCount = Int(outputBuffer.frameLength)
        let sampleCount = frameCount * Self.channelCount
        guard sampleCount > 0,
              let sampleData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw AudioSampleBufferNormalizerError.bufferAllocationFailed
        }

        let samples = UnsafeBufferPointer(
            start: sampleData.assumingMemoryBound(to: Float32.self),
            count: sampleCount
        )
        return try body(samples, frameCount)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        converter = nil
        inputFormatKey = nil
        inputBufferFormatKey = nil
        inputBuffer = nil
        outputBuffer = nil
    }

    private func normalizeOnLock(_ sampleBuffer: CMSampleBuffer) throws -> CMSampleBuffer? {
        guard let outputBuffer = try normalizePCMBufferOnLock(sampleBuffer) else {
            return nil
        }
        return try outputSampleBuffer(
            from: outputBuffer,
            sourcePresentationTime: sampleBuffer.presentationTimeStamp
        )
    }

    private func normalizePCMBufferOnLock(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }
        guard let formatDescription = sampleBuffer.formatDescription else {
            throw AudioSampleBufferNormalizerError.missingFormatDescription
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let inputDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw AudioSampleBufferNormalizerError.unsupportedInputFormat
        }

        let inputBuffer = try inputPCMBuffer(
            sampleBuffer: sampleBuffer,
            format: inputFormat,
            sampleCount: sampleCount,
            description: inputDescription
        )
        let converter = try converter(for: inputFormat, description: inputDescription)
        let outputCapacity = AVAudioFrameCount(
            max(1, Int(ceil(Double(sampleCount) * outputFormat.sampleRate / inputFormat.sampleRate)) + 256)
        )
        let outputBuffer = try reusableOutputPCMBuffer(frameCapacity: outputCapacity)
        outputBuffer.frameLength = 0

        let inputProvider = SingleInputProvider(inputBuffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputProvider.provide(inputStatus: inputStatus)
        }
        if status == .error {
            throw AudioSampleBufferNormalizerError.conversionFailed(
                conversionError?.localizedDescription ?? "Unknown converter error"
            )
        }
        guard outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    private func inputPCMBuffer(
        sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        sampleCount: Int,
        description: AudioStreamBasicDescription
    ) throws -> AVAudioPCMBuffer {
        let key = InputFormatKey(description)
        let frameCapacity = AVAudioFrameCount(sampleCount)
        if inputBufferFormatKey != key || inputBuffer?.frameCapacity ?? 0 < frameCapacity {
            guard let nextInputBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else {
                throw AudioSampleBufferNormalizerError.bufferAllocationFailed
            }
            inputBuffer = nextInputBuffer
            inputBufferFormatKey = key
        }
        guard let inputBuffer else {
            throw AudioSampleBufferNormalizerError.bufferAllocationFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw AudioSampleBufferNormalizerError.pcmCopyFailed(copyStatus)
        }
        return inputBuffer
    }

    private func reusableOutputPCMBuffer(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if outputBuffer?.frameCapacity ?? 0 < frameCapacity {
            guard let nextOutputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCapacity
            ) else {
                throw AudioSampleBufferNormalizerError.bufferAllocationFailed
            }
            outputBuffer = nextOutputBuffer
        }
        guard let outputBuffer else {
            throw AudioSampleBufferNormalizerError.bufferAllocationFailed
        }
        return outputBuffer
    }

    private func converter(
        for inputFormat: AVAudioFormat,
        description: AudioStreamBasicDescription
    ) throws -> AVAudioConverter {
        let key = InputFormatKey(description)
        if let converter, inputFormatKey == key {
            return converter
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioSampleBufferNormalizerError.unsupportedInputFormat
        }
        self.converter = converter
        inputFormatKey = key
        return converter
    }

    private func outputSampleBuffer(
        from outputBuffer: AVAudioPCMBuffer,
        sourcePresentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let sampleCount = Int(outputBuffer.frameLength)
        let byteCount = Int(outputBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        guard sampleCount > 0, byteCount > 0,
              let sourceData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw AudioSampleBufferNormalizerError.bufferAllocationFailed
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw AudioSampleBufferNormalizerError.blockBufferCreationFailed(blockStatus)
        }
        let replaceStatus = CMBlockBufferReplaceDataBytes(
            with: sourceData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw AudioSampleBufferNormalizerError.blockBufferCreationFailed(replaceStatus)
        }

        let presentationTime = sourcePresentationTime.isValid
            ? CMTimeConvertScale(
                sourcePresentationTime,
                timescale: CMTimeScale(Self.sampleRate),
                method: .roundHalfAwayFromZero
            )
            : .invalid

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var normalizedSampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: outputFormatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &normalizedSampleBuffer
        )
        guard sampleStatus == noErr, let normalizedSampleBuffer else {
            throw AudioSampleBufferNormalizerError.sampleBufferCreationFailed(sampleStatus)
        }
        return normalizedSampleBuffer
    }

    private static func makeAudioFormatDescription(
        for format: AVAudioFormat
    ) throws -> CMAudioFormatDescription {
        var streamDescription = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw AudioSampleBufferNormalizerError.audioFormatDescriptionCreationFailed(formatStatus)
        }
        return formatDescription
    }

    private struct InputFormatKey: Equatable {
        var sampleRate: Double
        var formatID: AudioFormatID
        var formatFlags: AudioFormatFlags
        var bytesPerPacket: UInt32
        var framesPerPacket: UInt32
        var bytesPerFrame: UInt32
        var channelsPerFrame: UInt32
        var bitsPerChannel: UInt32

        init(_ description: AudioStreamBasicDescription) {
            sampleRate = description.mSampleRate
            formatID = description.mFormatID
            formatFlags = description.mFormatFlags
            bytesPerPacket = description.mBytesPerPacket
            framesPerPacket = description.mFramesPerPacket
            bytesPerFrame = description.mBytesPerFrame
            channelsPerFrame = description.mChannelsPerFrame
            bitsPerChannel = description.mBitsPerChannel
        }
    }

    private final class SingleInputProvider: @unchecked Sendable {
        private var inputBuffer: AVAudioPCMBuffer?

        init(inputBuffer: AVAudioPCMBuffer) {
            self.inputBuffer = inputBuffer
        }

        func provide(inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let inputBuffer else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            self.inputBuffer = nil
            inputStatus.pointee = .haveData
            return inputBuffer
        }
    }
}
