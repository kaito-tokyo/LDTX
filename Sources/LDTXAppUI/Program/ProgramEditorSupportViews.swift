// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct ProgramDefinitionJSONView: View {
  @Environment(\.dismiss) private var dismiss
  var jsonText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Program Definition JSON")
          .font(.headline)

        Spacer()

        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }

      ScrollView {
        Text(jsonText)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(20)
    .frame(minWidth: 640, minHeight: 520)
  }
}

struct ProgramColorPicker: View {
  var title: String
  @Binding var red: Float
  @Binding var green: Float
  @Binding var blue: Float
  @Binding var alpha: Float

  init(
    _ title: String,
    red: Binding<Float>,
    green: Binding<Float>,
    blue: Binding<Float>,
    alpha: Binding<Float>
  ) {
    self.title = title
    _red = red
    _green = green
    _blue = blue
    _alpha = alpha
  }

  var body: some View {
    ColorPicker(title, selection: color, supportsOpacity: true)
  }

  private var color: Binding<Color> {
    Binding(
      get: {
        Color(
          .sRGB,
          red: Double(red),
          green: Double(green),
          blue: Double(blue),
          opacity: Double(alpha)
        )
      },
      set: { newValue in
        let color = NSColor(newValue).usingColorSpace(.sRGB) ?? NSColor(newValue)
        red = Float(color.redComponent)
        green = Float(color.greenComponent)
        blue = Float(color.blueComponent)
        alpha = Float(color.alphaComponent)
      }
    )
  }
}

struct ProgramParameterSlider: View {
  var title: String
  @Binding var value: Float
  var range: ClosedRange<Float>

  init(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) {
    self.title = title
    _value = value
    self.range = range
  }

  var body: some View {
    LabeledContent(title) {
      HStack {
        Slider(value: valueAsDouble, in: Double(range.lowerBound)...Double(range.upperBound))
        Text(value.formatted(.number.precision(.fractionLength(2))))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)
      }
    }
  }

  private var valueAsDouble: Binding<Double> {
    Binding(
      get: { Double(value) },
      set: { value = Float($0) }
    )
  }
}

#if DEBUG
  #Preview("Program Definition JSON") {
    ProgramDefinitionJSONView(
      jsonText: """
        {
          "name" : "Demo Program",
          "canvasWidth" : 1920,
          "canvasHeight" : 1080
        }
        """
    )
  }

  #Preview("Program Color Picker") {
    @Previewable @State var red: Float = 0.95
    @Previewable @State var green: Float = 0.18
    @Previewable @State var blue: Float = 0.26
    @Previewable @State var alpha: Float = 0.9

    ProgramColorPicker(
      "Accent Color",
      red: $red,
      green: $green,
      blue: $blue,
      alpha: $alpha
    )
    .padding()
    .frame(width: 280)
  }

  #Preview("Program Parameter Slider") {
    @Previewable @State var value: Float = 0.72

    ProgramParameterSlider("Opacity", value: $value, range: 0...1)
      .padding()
      .frame(width: 320)
  }
#endif
