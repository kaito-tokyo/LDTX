// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct TriggerEditor: View {
  @Binding var triggers: [Ldtx_Workspace_V4_VisionTriggerWrapper]
  @Environment(\.outputActive) var outputActive

  var body: some View {
    Picker("Update Interval", selection: $triggers) {
      Text("Manual").tag([Ldtx_Workspace_V4_VisionTriggerWrapper]())
      Text("Every 1 Second").tag([intervalTrigger(seconds: 1)])
      Text("Every 5 Seconds").tag([intervalTrigger(seconds: 5)])
      Text("Every 10 Seconds").tag([intervalTrigger(seconds: 10)])
      Text("Every 30 Seconds").tag([intervalTrigger(seconds: 30)])
    }
    .disabled(outputActive)
  }

  private func intervalTrigger(seconds: Int32) -> Ldtx_Workspace_V4_VisionTriggerWrapper {
    .with { $0.intervalTrigger.intervalSeconds.set(num: seconds, den: 1) }
  }
}

#if DEBUG
  #Preview {
    @Previewable @State var triggers = [Ldtx_Workspace_V4_VisionTriggerWrapper]()

    Form {
      TriggerEditor(triggers: $triggers)
    }
    .formStyle(.grouped)
  }
#endif
