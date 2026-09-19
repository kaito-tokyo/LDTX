// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
final class ApplicationWindowRestorer: NSObject, NSWindowRestoration {
  static var openWorkspace: ((URL) -> NSWindow?)?
  static var openRecording: ((URL) -> NSWindow?)?

  static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    guard
      let url = state.decodeObject(of: NSURL.self, forKey: "LDTX.AppKit.v1.url") as URL?,
      let kind = state.decodeObject(of: NSString.self, forKey: "LDTX.AppKit.v1.kind") as String?,
      FileManager.default.fileExists(atPath: url.path)
    else {
      completionHandler(nil, nil)
      return
    }
    let window: NSWindow?
    switch kind {
    case "workspace": window = openWorkspace?(url)
    case "recording": window = openRecording?(url)
    default: window = nil
    }
    window?.identifier = identifier
    completionHandler(window, nil)
  }
}
