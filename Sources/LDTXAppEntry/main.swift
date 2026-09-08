// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppCore
import SwiftUI

#if LDTX_FULL_APP
  import LDTXFullAppFeatures
  AppFeatureRegistry.provider = FullAppFeatureProvider()
#endif

LDTXApp.main()
