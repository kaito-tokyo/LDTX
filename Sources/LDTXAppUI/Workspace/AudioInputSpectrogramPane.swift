// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import MetalKit
import SwiftUI

struct AudioInputSpectrogramPane: View {
    var audioDeviceID: String?
    @StateObject private var controller = InputAudioSpectrogramController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Spectrogram")
                    .font(.headline)
                Spacer()
                Text(controller.statusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)

                if audioDeviceID == nil {
                    ContentUnavailableView(
                        "No Audio Device Selected",
                        systemImage: "speaker.slash",
                        description: Text("Choose a physical audio device to show a live filter-bank spectrogram here.")
                    )
                    .padding()
                } else if controller.snapshot.pixels.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for audio samples...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    AudioInputSpectrogramView(snapshot: controller.snapshot)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 240)
        }
        .onAppear {
            controller.configure(audioDeviceID: audioDeviceID)
        }
        .onChange(of: audioDeviceID) { _, newValue in
            controller.configure(audioDeviceID: newValue)
        }
        .onDisappear {
            controller.stop()
        }
    }
}

private struct AudioInputSpectrogramMetalView: NSViewRepresentable {
    var snapshot: InputAudioSpectrogramSnapshot

    func makeNSView(context: Context) -> AudioInputSpectrogramMTKView {
        let view = AudioInputSpectrogramMTKView()
        view.snapshot = snapshot
        return view
    }

    func updateNSView(_ nsView: AudioInputSpectrogramMTKView, context: Context) {
        nsView.snapshot = snapshot
    }
}

private struct AudioInputSpectrogramView: View {
    var snapshot: InputAudioSpectrogramSnapshot

    var body: some View {
        AudioInputSpectrogramMetalView(snapshot: snapshot)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                Text("0 - \(snapshot.sampleRate / 2) Hz")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
            }
    }
}

#if DEBUG
#Preview("Audio Spectrogram") {
    VStack {
        AudioInputSpectrogramMetalView(snapshot: previewSnapshot)
    }
    .padding()
    .frame(width: 520, height: 280)
}

private let previewSnapshot: InputAudioSpectrogramSnapshot = {
    let binCount = 96
    let columnCapacity = 180
    var pixels = [UInt8](repeating: 0, count: columnCapacity * binCount)
    for columnIndex in 0..<columnCapacity {
        for binIndex in 0..<binCount {
            let horizontal = Float(columnIndex) / Float(max(columnCapacity - 1, 1))
            let vertical = Float(binIndex) / Float(max(binCount - 1, 1))
            let ridgeA = exp(-pow((horizontal - 0.24) * 10, 2) - pow((vertical - 0.28) * 7, 2))
            let ridgeB = exp(-pow((horizontal - 0.58) * 14, 2) - pow((vertical - 0.66) * 9, 2))
            let ridgeC = exp(-pow((horizontal - 0.82) * 18, 2) - pow((vertical - 0.42) * 11, 2))
            let floor = max(0.08, (1 - vertical) * 0.12)
            let intensity = min(floor + ridgeA * 0.85 + ridgeB * 0.95 + ridgeC * 0.75, 1)
            let y = binCount - binIndex - 1
            pixels[y * columnCapacity + columnIndex] = UInt8(intensity * 255)
        }
    }
    return InputAudioSpectrogramSnapshot(
        pixels: pixels,
        columnCapacity: columnCapacity,
        binCount: binCount,
        sampleRate: 48_000,
        analysisBandCount: 128
    )
}()
#endif
