// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct MasterVolumeEditor: View {
  @Binding var volume: Double
  let peakProvider: () -> Float

  var body: some View {
    AudioChannelControl(
      label: "",
      value: ProgramPreferences.linearAudioChannelGain(fromDecibels: volume),
      showsValue: false,
      peakProvider: peakProvider,
      onPreview: {
        volume = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: $0)
      },
      onCommit: { _ in })
  }
}
