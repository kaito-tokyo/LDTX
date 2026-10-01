// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXDeviceRegistry
import Testing

@Suite
struct AudioInputDeviceUnitTestSuite {
  @Test func onlyDevicesWithInputChannelsAndIdentifiersAreListed() {
    let device = CoreAudioInputDeviceEnumerator.makeInputDevice(
      uid: "core-audio-uid",
      name: "USB Microphone",
      inputChannelCount: 2
    )
    #expect(
      device
        == AudioInputDevice(uid: "core-audio-uid", name: "USB Microphone", inputChannelCount: 2))
    #expect(device?.id == "core-audio-uid")
    #expect(
      CoreAudioInputDeviceEnumerator.makeInputDevice(
        uid: "core-audio-uid", name: "Output Only", inputChannelCount: 0) == nil)
    #expect(
      CoreAudioInputDeviceEnumerator.makeInputDevice(
        uid: "", name: "Unnamed Device", inputChannelCount: 1) == nil)
  }
}
