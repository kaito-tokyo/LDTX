// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

struct AudioChannelControl: View {
  @Binding var value: Double
  let peakProvider: () -> Float
  var showsValue = true
  var title = "Gain"

  var body: some View {
    HStack(spacing: 8) {
      Slider(value: $value, in: -80...20)
        .accessibilityLabel(title)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .background {
          AudioPeakMeter(peakProvider: peakProvider)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
      if showsValue {
        Text(value, format: .number.precision(.fractionLength(1)))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)
        Text("dB").foregroundStyle(.secondary)
      }
    }
  }
}

struct AudioPeakMeter: View {
  let peakProvider: () -> Float
  @State private var envelope = AudioPeakEnvelope()
  @State private var lastUpdate: Date?

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
      Canvas { context, size in
        let level = CGFloat(envelope.level)
        context.fill(Path(CGRect(origin: .zero, size: size)),
          with: .color(Color(red: 0.10, green: 0.11, blue: 0.12)))
        let segments: [(CGFloat, CGFloat, Color)] = [
          (0, 0.7, Color(red: 0.20, green: 0.78, blue: 0.42)),
          (0.7, 0.85, Color(red: 0.95, green: 0.72, blue: 0.25)),
          (0.85, 1, Color(red: 0.95, green: 0.28, blue: 0.24)),
        ]
        for (start, end, color) in segments where level > start {
          context.fill(
            Path(CGRect(x: size.width * start, y: 0,
              width: size.width * (min(level, end) - start), height: size.height)),
            with: .color(color))
        }
      }
      .onChange(of: timeline.date, initial: true) { _, date in
        envelope.update(peak: peakProvider(), elapsed: max(0, date.timeIntervalSince(lastUpdate ?? date)))
        lastUpdate = date
      }
    }
    .onDisappear { lastUpdate = nil }
    .accessibilityIdentifier("audioPeakMeter")
    .accessibilityHidden(true)
  }
}

struct AudioPeakEnvelope {
  private(set) var decibels: Float = -60
  var level: Float { min(1, max(0, (decibels + 60) / 60)) }

  mutating func update(peak: Float, elapsed: TimeInterval) {
    let measured: Float = peak.isFinite && peak > 0 ? 20 * log10(peak) : -60
    decibels = max(-60, min(0,
      max(measured, decibels - Float(max(0, elapsed)) * (20 / 1.7))))
  }
}
