// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct WorkspaceDetailEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "slider.horizontal.3",
            description: Text("Select an input device in the sidebar or a video component in the content pane.")
        )
    }
}
