// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "WorkspaceAudioEngine.h"
#include <vector>

namespace ldtx::audio {
// Values refer to the connected routes in their configured order. Input IDs
// alone are not identities: several logical routes may share the same input.
inline bool updateMonitorRouteGains(std::vector<LDTXAudioRoute> &routes, const std::vector<LDTXAudioRoute> &values) {
  if (routes.size() != values.size())
    return false;
  for (size_t i = 0; i < routes.size(); ++i)
    if (routes[i].input != values[i].input)
      return false;
  for (size_t i = 0; i < routes.size(); ++i)
    routes[i].gain = values[i].gain;
  return true;
}
} // namespace ldtx::audio
