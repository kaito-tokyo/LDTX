// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

struct AutomationDetailPane: View {
    @Binding var automations: [WorkspaceAutomationDefinition]
    var automationID: String
    var visions: [WorkspaceVisionDefinition]
    var inputDevices: [WorkspaceInputDeviceRecord]
    var run: (WorkspaceAutomationDefinition) -> Void
    var delete: (String) -> Void
    @State private var draftAutomationName = ""
    @FocusState private var isAutomationNameFieldFocused: Bool

    var body: some View {
        if let index = automations.firstIndex(where: { $0.id == automationID }) {
            Form {
                Section("Automation") {
                    TextField("Name", text: $draftAutomationName)
                        .focused($isAutomationNameFieldFocused)
                        .onSubmit { commitAutomationName() }
                    Toggle("Enabled", isOn: $automations[index].isEnabled)
                    triggerEditor(index: index)
                }

                Section("Actions") {
                    ForEach(Array(automations[index].actions.enumerated()), id: \.offset) { actionIndex, action in
                        actionEditor(automationIndex: index, actionIndex: actionIndex, action: action)
                    }
                    Menu("Add Action", systemImage: "plus") {
                        Button("Analyze Vision") {
                            automations[index].actions.append(.makeAnalyzeVision(visionName: visions.first?.name ?? ""))
                        }
                        Button("Select Input Device") {
                            automations[index].actions.append(
                                .makeSelectInputDevice(inputDeviceName: inputDevices.first?.name ?? "")
                            )
                        }
                    }
                }

                Section {
                    Button("Delete Automation", role: .destructive) { delete(automationID) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(automations[index].name)
            .onAppear { refreshDraftAutomationName() }
            .onChange(of: automationID) { _, _ in refreshDraftAutomationName() }
            .onChange(of: automations[index].name) { _, name in
                guard !isAutomationNameFieldFocused else { return }
                draftAutomationName = name
            }
            .onChange(of: isAutomationNameFieldFocused) { _, isFocused in
                if !isFocused { commitAutomationName() }
            }
        } else {
            WorkspaceDetailEmptyStateView()
        }
    }

    private func refreshDraftAutomationName() {
        draftAutomationName = automations.first(where: { $0.id == automationID })?.name ?? ""
    }

    private func commitAutomationName() {
        guard let index = automations.firstIndex(where: { $0.id == automationID }) else { return }
        let currentName = automations[index].name
        let proposedName = draftAutomationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proposedName != currentName else {
            draftAutomationName = currentName
            return
        }
        guard WorkspaceResourceNameValidator.isAvailable(
            proposedName,
            inputDevices: inputDevices,
            visions: visions,
            automations: automations,
            excludingResourceID: currentName
        ) else {
            draftAutomationName = currentName
            return
        }
        automations[index].name = proposedName
    }

    @ViewBuilder
    private func triggerEditor(index: Int) -> some View {
        Picker("Trigger", selection: triggerKindBinding(index: index)) {
            Text("Manual").tag("manual")
            Text("Interval").tag("interval")
        }
        switch automations[index].trigger {
        case .manual:
            EmptyView()
        case let .interval(seconds):
            LabeledContent("Interval") {
                TextField("Seconds", value: intervalBinding(index: index, fallback: seconds), format: .number)
                    .frame(width: 100)
                Text("seconds")
            }
        }
    }

    @ViewBuilder
    private func actionEditor(automationIndex: Int, actionIndex: Int, action: WorkspaceAutomationAction) -> some View {
        HStack {
            switch action {
            case let .analyzeVision(visionName):
                visionPicker("Analyze", selection: Binding(
                    get: { visionName },
                    set: { automations[automationIndex].actions[actionIndex] = .analyzeVision(visionName: $0) }
                ))
            case let .selectInputDevice(inputDeviceName):
                Picker("Select", selection: Binding(
                    get: { inputDeviceName },
                    set: {
                        automations[automationIndex].actions[actionIndex] =
                            .selectInputDevice(inputDeviceName: $0)
                    }
                )) {
                    referenceOptions(
                        values: inputDevices.map { ($0.id, $0.name) },
                        selectedID: inputDeviceName,
                        missingLabel: "Missing Input Device"
                    )
                }
            }
            Button(role: .destructive) { automations[automationIndex].actions.remove(at: actionIndex) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func visionPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            referenceOptions(
                values: visions.map { ($0.id, $0.name) },
                selectedID: selection.wrappedValue,
                missingLabel: "Missing Vision"
            )
        }
    }

    @ViewBuilder
    private func referenceOptions(values: [(String, String)], selectedID: String, missingLabel: String) -> some View {
        ForEach(values, id: \.0) { id, name in Text(name).tag(id) }
        if !values.contains(where: { $0.0 == selectedID }) {
            Text("\(missingLabel) (\(selectedID))").tag(selectedID)
        }
    }

    private func triggerKindBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                switch automations[index].trigger {
                case .manual: "manual"
                case .interval: "interval"
                }
            },
            set: { kind in
                switch kind {
                case "interval": automations[index].trigger = .interval(seconds: 5)
                default: automations[index].trigger = .manual
                }
            }
        )
    }

    private func intervalBinding(index: Int, fallback: Double) -> Binding<Double> {
        Binding(
            get: {
                if case let .interval(seconds) = automations[index].trigger { return seconds }
                return fallback
            },
            set: { automations[index].trigger = .interval(seconds: max($0, 0.1)) }
        )
    }
}
