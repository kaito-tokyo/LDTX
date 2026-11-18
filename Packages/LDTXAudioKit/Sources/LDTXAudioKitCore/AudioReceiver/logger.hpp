// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <os/log.h>

namespace LDTXAudioKit::AudioReceiverDetail {

inline auto logger() -> os_log_t {
  static os_log_t singleton = os_log_create("tokyo.kaito.ldtx", "audiokit.audio-receiver");
  return singleton;
}

} // namespace LDTXAudioKit::AudioReceiverDetail
