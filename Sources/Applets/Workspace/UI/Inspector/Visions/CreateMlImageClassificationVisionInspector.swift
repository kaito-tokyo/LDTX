// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import SwiftUI

struct CreateMlImageClassifierVisionInspector: View {
  @Bindable var storeService: WorkspaceStoreService
  @Binding var vision: Ldtx_Workspace_V4_CreateMlImageClassifierVision

  @State var x: Int32?
  @State var xDenominator: UInt32?
  @State var y: Int32?
  @State var yDenominator: UInt32?
  @State var width: Int32?
  @State var widthDenominator: UInt32?
  @State var height: Int32?
  @State var heightDenominator: UInt32?
  @State var validatorID = UUID()
  @State var submittedInputs: [Int64?] = []

  init(
    storeService: WorkspaceStoreService,
    vision: Binding<Ldtx_Workspace_V4_CreateMlImageClassifierVision>
  ) {
    self.storeService = storeService
    self._vision = vision
    let region = vision.wrappedValue.regionOfInterest
    let profile = WorkspaceCanvasTarget.landscape.defaultProfile
    let xFields = RationalFractionInput.fields(
      for: region.x, defaultDenominator: UInt32(profile.width))
    self._x = State(initialValue: Int32(xFields.numerator)!)
    self._xDenominator = State(initialValue: UInt32(xFields.denominator)!)
    let yFields = RationalFractionInput.fields(
      for: region.y, defaultDenominator: UInt32(profile.height))
    self._y = State(initialValue: Int32(yFields.numerator)!)
    self._yDenominator = State(initialValue: UInt32(yFields.denominator)!)
    let widthFields = RationalFractionInput.fields(
      for: region.width, defaultDenominator: UInt32(profile.width))
    self._width = State(initialValue: Int32(widthFields.numerator)!)
    self._widthDenominator = State(initialValue: UInt32(widthFields.denominator)!)
    let heightFields = RationalFractionInput.fields(
      for: region.height, defaultDenominator: UInt32(profile.height))
    self._height = State(initialValue: Int32(heightFields.numerator)!)
    self._heightDenominator = State(initialValue: UInt32(heightFields.denominator)!)
  }

  var body: some View {
    Form {
      Section("Vision - Create ML Image Classifier") {
        TextField("Name", text: $vision.displayName)
        Picker("Input video", selection: $vision.videoComponentInternalIDIfPresent) {
          Text("Unassigned").tag(UInt64?.none)
          ForEach(storeService.videoComponentOptions) { option in
            Text(option.name).tag(Optional(option.id))
          }
        }
        .pickerStyle(.automatic)
        Picker("Update Interval", selection: $vision.triggers) {
          Text("Manual").tag([Ldtx_Workspace_V4_VisionTriggerWrapper]())
          Text("Every 1 Second").tag([intervalTrigger(seconds: 1)])
          Text("Every 5 Seconds").tag([intervalTrigger(seconds: 5)])
          Text("Every 10 Seconds").tag([intervalTrigger(seconds: 10)])
          Text("Every 30 Seconds").tag([intervalTrigger(seconds: 30)])
        }
      }
      .disabled(storeService.isOutputActive)
      Section("Region of Interest") {
        LabeledContent("X") {
          HStack {
            TextField("X numerator", value: $x, formatter: NullableIntegerFormatter<Int32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
            Text("/")
            TextField("X denominator", value: $xDenominator, formatter: NullableIntegerFormatter<UInt32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
        }
        LabeledContent("Y") {
          HStack {
            TextField("Y numerator", value: $y, formatter: NullableIntegerFormatter<Int32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
            Text("/")
            TextField("Y denominator", value: $yDenominator, formatter: NullableIntegerFormatter<UInt32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
        }
        LabeledContent("Width") {
          HStack {
            TextField("Width numerator", value: $width, formatter: NullableIntegerFormatter<Int32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
            Text("/")
            TextField("Width denominator", value: $widthDenominator, formatter: NullableIntegerFormatter<UInt32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
        }
        LabeledContent("Height") {
          HStack {
            TextField("Height numerator", value: $height, formatter: NullableIntegerFormatter<Int32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
            Text("/")
            TextField("Height denominator", value: $heightDenominator, formatter: NullableIntegerFormatter<UInt32>())
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
        }
      }
      .disabled(storeService.isOutputActive)
    }
    .formStyle(.grouped)
    .onSubmit { submitEdits() }
    .onAppear {
      if submittedInputs.isEmpty { submittedInputs = inputs }
      storeService.registerInspectorEditValidator(
        id: validatorID, hasChanges: { inputs != submittedInputs },
        submit: { try commitEdits() }
      ) {
        _ = try Self.validatedRegion(
          x: x, y: y, width: width, height: height, xDenominator: xDenominator,
          yDenominator: yDenominator,
          widthDenominator: widthDenominator, heightDenominator: heightDenominator)
      }
    }
    .onChange(of: inputs) { storeService.refreshUnconfirmedChanges() }
    .onDisappear { storeService.removeInspectorEditValidator(id: validatorID) }
  }

  var inputs: [Int64?] {
    [
      x.map { Int64($0) }, xDenominator.map { Int64($0) }, y.map { Int64($0) }, yDenominator.map { Int64($0) }, width.map { Int64($0) },
      widthDenominator.map { Int64($0) }, height.map { Int64($0) }, heightDenominator.map { Int64($0) },
    ]
  }

  func intervalTrigger(seconds: Int32) -> Ldtx_Workspace_V4_VisionTriggerWrapper {
    .with { $0.intervalTrigger.intervalSeconds.set(num: seconds, den: 1) }
  }

  func submitEdits() {
    guard !storeService.isOutputActive else { return }
    do { try commitEdits() } catch { storeService.reportInputValidationError(error) }
  }

  func commitEdits() throws {
    let region = try Self.validatedRegion(
      x: x, y: y, width: width, height: height, xDenominator: xDenominator,
      yDenominator: yDenominator,
      widthDenominator: widthDenominator, heightDenominator: heightDenominator)
    vision.regionOfInterest = region
    submittedInputs = inputs
    storeService.refreshUnconfirmedChanges()
  }

  static func validatedRegion(
    x: Int32?, y: Int32?, width: Int32?, height: Int32?,
    xDenominator: UInt32? = 1, yDenominator: UInt32? = 1,
    widthDenominator: UInt32? = 1, heightDenominator: UInt32? = 1
  ) throws
    -> Ldtx_Workspace_V4_VisionRegionOfInterest
  {
    do {
      guard let x, let y, let width, let height,
        let xDenominator, let yDenominator, let widthDenominator, let heightDenominator
      else { throw RationalInputError.invalidNumber }
      guard xDenominator > 0, yDenominator > 0, widthDenominator > 0, heightDenominator > 0
      else { throw RationalInputError.zeroDenominator }
      var region = Ldtx_Workspace_V4_VisionRegionOfInterest()
      region.x.set(num: x, den: xDenominator)
      region.y.set(num: y, den: yDenominator)
      region.width.set(num: width, den: widthDenominator)
      region.height.set(num: height, den: heightDenominator)
      try WorkspaceV4IntegrityValidator.validateRegionOfInterest(region)
      return region
    } catch {
      throw WorkspaceSelectionError(
        message: "Correct the classifier ROI before applying changes. "
          + error.localizedDescription)
    }
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .createMlImageClassifierVision, internalID: 11))
    @Bindable var boundStore = storeService
    if let vision = $boundStore.createMlImageClassifierVision(internalID: 11) {
      CreateMlImageClassifierVisionInspector(storeService: storeService, vision: vision)
        .frame(width: 480, height: 600, alignment: .topLeading)
    }
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .createMlImageClassifierVision, internalID: 11),
      isOutputActive: true)
    @Bindable var boundStore = storeService
    if let vision = $boundStore.createMlImageClassifierVision(internalID: 11) {
      CreateMlImageClassifierVisionInspector(storeService: storeService, vision: vision)
        .frame(width: 480, height: 600, alignment: .topLeading)
    }
  }
#endif
