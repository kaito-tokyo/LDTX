// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct LauncherContent: View {
  private let newWorkspace: () -> Void
  private let openFile: () -> Void

  public init(newWorkspace: @escaping () -> Void, openFile: @escaping () -> Void) {
    self.newWorkspace = newWorkspace
    self.openFile = openFile
  }

  public var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "video.badge.waveform").font(.system(size: 44)).foregroundStyle(.tint)
      Text("LDTX").font(.largeTitle.bold())
      HStack {
        Button("New Workspace", action: newWorkspace).keyboardShortcut(.defaultAction)
        Button("Open File…", action: openFile)
      }
    }
    .padding(36)
  }
}
