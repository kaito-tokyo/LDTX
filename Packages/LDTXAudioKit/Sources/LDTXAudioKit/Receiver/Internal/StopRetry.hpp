// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once

namespace ldtx::audio {
// Control-thread operation only. A successful stop establishes quiescence;
// elapsed time alone never does. Return the last failure to the owner.
template <class Stop, class BeforeRetry> auto retryStop(Stop stop, BeforeRetry beforeRetry) {
  auto status = stop();
  for (unsigned retry = 0; status != 0 && retry < 3; ++retry) {
    beforeRetry();
    status = stop();
  }
  return status;
}
} // namespace ldtx::audio
