// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import LDTXAppCore

#if LDTX_FULL_APP
import LDTXFullAppFeatures
AppFeatureRegistry.provider = FullAppFeatureProvider()
#endif

#if DEBUG
private struct LDTXPreviewApp: App {
    var body: some Scene {
        WindowGroup("LDTX Preview") {
            Text("LDTX Preview")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 320, height: 200)
        }
    }
}

if LDTXRuntimeMode.isPreview {
    LDTXPreviewApp.main()
} else {
    LDTXApp.main()
}
#else
LDTXApp.main()
#endif
