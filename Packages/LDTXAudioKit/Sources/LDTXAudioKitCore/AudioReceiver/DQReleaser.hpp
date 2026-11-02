// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <dispatch/dispatch.h>

namespace LDTXAudioKit::AudioReceiverDetail {

struct DQReleaser {
  void operator()(dispatch_queue_t queue) {
    if (queue != nullptr) {
      dispatch_release(queue);
    }
  }
};

} // namespace LDTXAudioKit::AudioReceiverDetail
