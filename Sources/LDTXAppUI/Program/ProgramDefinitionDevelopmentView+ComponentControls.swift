// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

extension ProgramDefinitionDevelopmentView {
  @ViewBuilder
  func componentParameterControls(
    for step: Binding<CompositeProgramStep>
  ) -> some View {
    let component = step.component
    switch component.wrappedValue {
    case .fillSolidColor:
      solidColorControls(payload: solidColorBinding(for: component))
    case .fillLinearGradient:
      linearGradientControls(payload: linearGradientBinding(for: component))
    case .fillRadialGradient:
      radialGradientControls(payload: radialGradientBinding(for: component))
    case .fillConicGradient:
      conicGradientControls(payload: conicGradientBinding(for: component))
    case .clock:
      clockControls(payload: clockBinding(for: component))
    case .inputCameraDevice:
      inputCameraDeviceControls(
        payload: inputCameraDeviceBinding(for: component)
      )
    case .testPattern:
      noParameterControls
    }
  }

  var noParameterControls: some View {
    Text("No parameters")
      .foregroundStyle(.secondary)
  }

  private func solidColorControls(payload: Binding<FillSolidColorComponent>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ProgramColorPicker(
        "colorPicker",
        red: payload.red,
        green: payload.green,
        blue: payload.blue,
        alpha: payload.alpha
      )
      .labelsHidden()
      .accessibilityLabel("colorPicker")
      .accessibilityIdentifier("colorPicker")
      .help("colorPicker")

      solidColorClipControls(payload.clip)
    }
  }

  private func linearGradientControls(payload: Binding<FillLinearGradientComponent>) -> some View {
    Group {
      ProgramParameterSlider("Start X", value: payload.startX, range: 0...1)
      ProgramParameterSlider("Start Y", value: payload.startY, range: 0...1)
      ProgramParameterSlider("End X", value: payload.endX, range: 0...1)
      ProgramParameterSlider("End Y", value: payload.endY, range: 0...1)
      ProgramColorPicker(
        "Start Color",
        red: payload.startRed,
        green: payload.startGreen,
        blue: payload.startBlue,
        alpha: payload.startAlpha
      )
      ProgramColorPicker(
        "End Color",
        red: payload.endRed,
        green: payload.endGreen,
        blue: payload.endBlue,
        alpha: payload.endAlpha
      )
      fillClipControls(payload.clip)
    }
  }

  private func radialGradientControls(payload: Binding<FillRadialGradientComponent>) -> some View {
    Group {
      ProgramParameterSlider("Center X", value: payload.centerX, range: 0...1)
      ProgramParameterSlider("Center Y", value: payload.centerY, range: 0...1)
      ProgramParameterSlider("Inner Radius", value: payload.innerRadius, range: 0...1)
      ProgramParameterSlider("Outer Radius", value: payload.outerRadius, range: 0.01...1.5)
      ProgramColorPicker(
        "Inner Color",
        red: payload.innerRed,
        green: payload.innerGreen,
        blue: payload.innerBlue,
        alpha: payload.innerAlpha
      )
      ProgramColorPicker(
        "Outer Color",
        red: payload.outerRed,
        green: payload.outerGreen,
        blue: payload.outerBlue,
        alpha: payload.outerAlpha
      )
      fillClipControls(payload.clip)
    }
  }

  private func conicGradientControls(payload: Binding<FillConicGradientComponent>) -> some View {
    Group {
      ProgramParameterSlider("Center X", value: payload.centerX, range: 0...1)
      ProgramParameterSlider("Center Y", value: payload.centerY, range: 0...1)
      ProgramParameterSlider(
        "Start Angle", value: payload.startAngleRadians, range: 0...(Float.pi * 2))
      ProgramColorPicker(
        "Start Color",
        red: payload.startRed,
        green: payload.startGreen,
        blue: payload.startBlue,
        alpha: payload.startAlpha
      )
      ProgramColorPicker(
        "End Color",
        red: payload.endRed,
        green: payload.endGreen,
        blue: payload.endBlue,
        alpha: payload.endAlpha
      )
      fillClipControls(payload.clip)
    }
  }

  private func clockControls(payload: Binding<ClockComponent>) -> some View {
    ClockStyleControls(component: payload)
  }

  private func fillClipControls(_ clip: Binding<FillClip>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Clip")
        .font(.headline)

      HStack(spacing: 8) {
        ProgramTableFloatField(value: clip.top, unit: "px", fractionDigits: 0)
        ProgramTableFloatField(value: clip.right, unit: "px", fractionDigits: 0)
        ProgramTableFloatField(value: clip.bottom, unit: "px", fractionDigits: 0)
        ProgramTableFloatField(value: clip.left, unit: "px", fractionDigits: 0)
      }
    }
  }

  private func solidColorClipControls(_ clip: Binding<FillClip>) -> some View {
    HStack(spacing: 8) {
      solidColorClipField(value: clip.top, accessibilityName: "clipTop")
      solidColorClipField(value: clip.right, accessibilityName: "clipRight")
      solidColorClipField(value: clip.bottom, accessibilityName: "clipBottom")
      solidColorClipField(value: clip.left, accessibilityName: "clipLeft")
    }
  }

  private func solidColorClipField(
    value: Binding<Float>,
    accessibilityName: String
  ) -> some View {
    ProgramTableFloatField(value: value, unit: "px", fractionDigits: 0)
      .accessibilityLabel(accessibilityName)
      .accessibilityIdentifier(accessibilityName)
      .help(accessibilityName)
  }

  private func inputCameraDeviceControls(
    payload: Binding<InputDeviceComponent>
  ) -> some View {
    Group {
      videoInputDeviceControl(payload: payload)

      VStack(alignment: .leading, spacing: 8) {
        Text("Source Crop")
          .font(.headline)

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
          GridRow {
            Text("Top")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.sourceCropTop, unit: "%", fractionDigits: 0)
            Text("Right")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.sourceCropRight, unit: "%", fractionDigits: 0)
          }
          GridRow {
            Text("Bottom")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.sourceCropBottom, unit: "%", fractionDigits: 0)
            Text("Left")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.sourceCropLeft, unit: "%", fractionDigits: 0)
          }
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Destination")
          .font(.headline)

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
          GridRow {
            Text("X")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.destinationX, unit: "px", fractionDigits: 0)
            Text("Y")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.destinationY, unit: "px", fractionDigits: 0)
          }
          GridRow {
            Text("Scale")
              .foregroundStyle(.secondary)
            ProgramTableFloatField(value: payload.destinationScale, unit: "x", fractionDigits: 2)
          }
        }
      }
    }
  }

  private func videoInputDeviceControl(payload: Binding<InputDeviceComponent>) -> some View {
    LabeledContent {
      HStack {
        Spacer(minLength: 12)

        Picker(selection: payload.inputDeviceID) {
          Text("No input device").tag(Optional<String>.none)
          ForEach(videoInputDevices) { inputDevice in
            Text(inputDevice.name).tag(Optional(inputDevice.id))
          }
        } label: {
          Text("Input Device")
        }
        .labelsHidden()
        .frame(maxWidth: 300, alignment: .trailing)
        .accessibilityIdentifier("inputCameraDevicePicker")
      }
    } label: {
      Text("Input Device")
        .lineLimit(1)
    }
  }

  private var videoInputDevices: [WorkspaceInputDeviceRecord] {
    workspaceInputDevices.filter { $0.kind == .video }
  }

  private func solidColorBinding(for component: Binding<ProgramComponent>) -> Binding<
    FillSolidColorComponent
  > {
    Binding(
      get: {
        if case .fillSolidColor(let payload) = component.wrappedValue {
          return payload
        }
        return FillSolidColorComponent()
      },
      set: { component.wrappedValue = .fillSolidColor($0) }
    )
  }

  private func linearGradientBinding(for component: Binding<ProgramComponent>) -> Binding<
    FillLinearGradientComponent
  > {
    Binding(
      get: {
        if case .fillLinearGradient(let payload) = component.wrappedValue {
          return payload
        }
        return FillLinearGradientComponent()
      },
      set: { component.wrappedValue = .fillLinearGradient($0) }
    )
  }

  private func radialGradientBinding(for component: Binding<ProgramComponent>) -> Binding<
    FillRadialGradientComponent
  > {
    Binding(
      get: {
        if case .fillRadialGradient(let payload) = component.wrappedValue {
          return payload
        }
        return FillRadialGradientComponent()
      },
      set: { component.wrappedValue = .fillRadialGradient($0) }
    )
  }

  private func conicGradientBinding(for component: Binding<ProgramComponent>) -> Binding<
    FillConicGradientComponent
  > {
    Binding(
      get: {
        if case .fillConicGradient(let payload) = component.wrappedValue {
          return payload
        }
        return FillConicGradientComponent()
      },
      set: { component.wrappedValue = .fillConicGradient($0) }
    )
  }

  private func clockBinding(for component: Binding<ProgramComponent>) -> Binding<ClockComponent> {
    Binding(
      get: {
        if case .clock(let payload) = component.wrappedValue {
          return payload
        }
        return ClockComponent()
      },
      set: { component.wrappedValue = .clock($0) }
    )
  }

  private func inputCameraDeviceBinding(for component: Binding<ProgramComponent>) -> Binding<
    InputDeviceComponent
  > {
    Binding(
      get: {
        if case .inputCameraDevice(let payload) = component.wrappedValue {
          return payload
        }
        return InputDeviceComponent()
      },
      set: { component.wrappedValue = .inputCameraDevice($0) }
    )
  }

}
