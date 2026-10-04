// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct VideoLayerTransformEditor: View {
  @Binding var posXStr: String
  @Binding var posYStr: String
  @Binding var scaleXStr: String
  @Binding var scaleYStr: String

  var posX: Double? { Double(posXStr) }
  var posY: Double? { Double(posYStr) }
  var scaleX: Double? { Double(scaleXStr) }
  var scaleY: Double? { Double(scaleYStr) }

  var isValid: Bool {
    posX?.isFinite == true && posY?.isFinite == true
      && scaleX?.isFinite == true && scaleY?.isFinite == true
  }

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        TextField("Pos X", text: $posXStr)
        TextField("Pos Y", text: $posYStr)
        TextField("Scale X", text: $scaleXStr)
        TextField("Scale Y", text: $scaleYStr)
      }
      .autocorrectionDisabled(true)
      if !isValid {
        Text("Invalid number.")
      }
    }
  }
}

#if DEBUG
  #Preview {
    @Previewable @State var posX = "0.0"
    @Previewable @State var posY = "0.0"
    @Previewable @State var scaleX = "1.0"
    @Previewable @State var scaleY = "1.0"
    Form {
      VideoLayerTransformEditor(
        posXStr: $posX, posYStr: $posY, scaleXStr: $scaleX, scaleYStr: $scaleY)
    }
    .padding()
    .frame(width: 640)
  }
#endif
