// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct RegionOfInterestEditor: View {
  let inputSize: (width: UInt32, height: UInt32)
  @Binding var roi: Ldtx_Workspace_V4_VisionRegionOfInterest

  init(
    inputSize: (width: UInt32, height: UInt32),
    roi: Binding<Ldtx_Workspace_V4_VisionRegionOfInterest>
  ) {
    self.inputSize = inputSize
    self._roi = roi
  }

  static func numeratorBinding<Value: Rational32Value>(
    _ value: Binding<Value>, defaultDenominator: UInt32
  ) -> Binding<Int32?> {
    Binding(
      get: { value.wrappedValue.numIfPresent },
      set: { numerator in
        var rational = value.wrappedValue
        rational.numIfPresent = numerator
        if numerator != nil && !rational.hasDen {
          rational.den = defaultDenominator
        }
        value.wrappedValue = rational
      })
  }

  private func rationalTextField<Value: Rational32Value>(
    value: Binding<Value>,
    numeratorPrompt: Text?,
    defaultDenominator: UInt32,
    numeratorLabel: LocalizedStringResource,
    denominatorLabel: LocalizedStringResource
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      TextField(
        numeratorLabel,
        value: Self.numeratorBinding(value, defaultDenominator: defaultDenominator),
        formatter: NullableIntegerFormatter<Int32>(),
        prompt: numeratorPrompt
      )
      .frame(width: 40)
      Text("/")
      TextField(
        denominatorLabel,
        value: value.denIfPresent,
        formatter: NullableIntegerFormatter<UInt32>(),
        prompt: Text(String(defaultDenominator))
      )
      .frame(width: 40)
    }
    .labelsHidden()
  }

  var body: some View {
    LabeledContent("X") {
      rationalTextField(
        value: $roi.x,
        numeratorPrompt: Text("0"),
        defaultDenominator: inputSize.width,
        numeratorLabel: "X numerator",
        denominatorLabel: "X denominator")
    }
    LabeledContent("Y") {
      rationalTextField(
        value: $roi.y,
        numeratorPrompt: Text("0"),
        defaultDenominator: inputSize.height,
        numeratorLabel: "Y numerator",
        denominatorLabel: "Y denominator")
    }
    LabeledContent("Width") {
      rationalTextField(
        value: $roi.width,
        numeratorPrompt: Text(String(inputSize.width)),
        defaultDenominator: inputSize.width,
        numeratorLabel: "Width numerator",
        denominatorLabel: "Width denominator")
    }
    LabeledContent("Height") {
      rationalTextField(
        value: $roi.height,
        numeratorPrompt: Text(String(inputSize.height)),
        defaultDenominator: inputSize.height,
        numeratorLabel: "Height numerator",
        denominatorLabel: "Height denominator")
    }
  }
}

#if DEBUG
  #Preview {
    @Previewable @State var roi = Ldtx_Workspace_V4_VisionRegionOfInterest()

    Form {
      RegionOfInterestEditor(inputSize: (1920, 1080), roi: $roi)
    }
    .formStyle(.grouped)
  }
#endif
