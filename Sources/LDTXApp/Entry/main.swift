// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

#if LDTX_FULL_APP
  AppFeatureRegistry.provider = FullAppFeatureProvider()
#endif

LDTXApp.main()
