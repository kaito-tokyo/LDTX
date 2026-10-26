// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import LDTXCorelibs
import LDTXWorkspaceAppletInterface

final class StubAudioPeakMeter: ProgramAudioPeakMeterPresenting {
  func peak(for master: WorkspaceAudioMaster) -> Float { 0 }
  func peak(for channelKey: String) -> Float { 0 }
}
