// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

public struct LauncherContent: View {
  public init() {}

  public var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "video.badge.waveform").font(.system(size: 44)).foregroundStyle(.tint)
      Text("LDTX").font(.largeTitle.bold())
      HStack {
        Button("New Workspace") { NSDocumentController.shared.newDocument(nil) }
          .keyboardShortcut(.defaultAction)
        Button("Open File…") { NSDocumentController.shared.openDocument(nil) }
      }
    }
    .padding(36)
  }
}
