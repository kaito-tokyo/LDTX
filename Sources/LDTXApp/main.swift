// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

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
