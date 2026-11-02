// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <AudioToolbox/AudioToolbox.h>

namespace LDTXAudioKit::AudioReceiverDetail {

struct ACIReleaser {
  void operator()(AudioComponentInstance comp) {
    if (comp != nullptr) {
      AudioComponentInstanceDispose(comp);
    }
  }
};

} // namespace LDTXAudioKit::AudioReceiverDetail
