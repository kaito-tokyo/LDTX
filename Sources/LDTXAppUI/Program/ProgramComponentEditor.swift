// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramComponentEditor: View {
    @Binding var step: CompositeProgramStep
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Component", selection: componentDefinitionBinding) {
                ForEach(ProgramComponentDefinition.allCases) { definition in
                    Text(definition.displayName).tag(definition)
                }
            }
            .accessibilityIdentifier("programComponentPicker")

            componentParameterControls
        }
    }

    @ViewBuilder
    private var componentParameterControls: some View {
        switch componentBinding.wrappedValue {
        case .fillSolidColor:
            solidColorControls(payload: solidColorBinding)
        case .fillLinearGradient:
            linearGradientControls(payload: linearGradientBinding)
        case .fillRadialGradient:
            radialGradientControls(payload: radialGradientBinding)
        case .fillConicGradient:
            conicGradientControls(payload: conicGradientBinding)
        case .inputCameraDevice:
            inputCameraDeviceControls(payload: inputCameraDeviceBinding)
        case .testPattern:
            noParameterControls
        }
    }

    private var componentBinding: Binding<ProgramComponent> {
        $step.component
    }

    private var componentDefinitionBinding: Binding<ProgramComponentDefinition> {
        Binding(
            get: { step.component.definition },
            set: { newValue in
                step.component = .defaultComponent(for: newValue)
            }
        )
    }

    private var noParameterControls: some View {
        Text("No parameters")
            .foregroundStyle(.secondary)
    }

    private func solidColorControls(payload: Binding<FillSolidColorComponent>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgramColorPicker(
                "Color",
                red: payload.red,
                green: payload.green,
                blue: payload.blue,
                alpha: payload.alpha
            )
            .accessibilityLabel("colorPicker")
            .accessibilityIdentifier("colorPicker")

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
            ProgramParameterSlider("Start Angle", value: payload.startAngleRadians, range: 0...(Float.pi * 2))
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

    private func inputCameraDeviceControls(payload: Binding<InputDeviceComponent>) -> some View {
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

    private var solidColorBinding: Binding<FillSolidColorComponent> {
        Binding(
            get: {
                if case let .fillSolidColor(payload) = componentBinding.wrappedValue {
                    return payload
                }
                return FillSolidColorComponent()
            },
            set: { componentBinding.wrappedValue = .fillSolidColor($0) }
        )
    }

    private var linearGradientBinding: Binding<FillLinearGradientComponent> {
        Binding(
            get: {
                if case let .fillLinearGradient(payload) = componentBinding.wrappedValue {
                    return payload
                }
                return FillLinearGradientComponent()
            },
            set: { componentBinding.wrappedValue = .fillLinearGradient($0) }
        )
    }

    private var radialGradientBinding: Binding<FillRadialGradientComponent> {
        Binding(
            get: {
                if case let .fillRadialGradient(payload) = componentBinding.wrappedValue {
                    return payload
                }
                return FillRadialGradientComponent()
            },
            set: { componentBinding.wrappedValue = .fillRadialGradient($0) }
        )
    }

    private var conicGradientBinding: Binding<FillConicGradientComponent> {
        Binding(
            get: {
                if case let .fillConicGradient(payload) = componentBinding.wrappedValue {
                    return payload
                }
                return FillConicGradientComponent()
            },
            set: { componentBinding.wrappedValue = .fillConicGradient($0) }
        )
    }

    private var inputCameraDeviceBinding: Binding<InputDeviceComponent> {
        Binding(
            get: {
                if case let .inputCameraDevice(payload) = componentBinding.wrappedValue {
                    return payload
                }
                return InputDeviceComponent()
            },
            set: { componentBinding.wrappedValue = .inputCameraDevice($0) }
        )
    }
}
