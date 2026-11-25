// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Persists and restores access to user-selected folders under the App Sandbox.
///
/// A sandboxed app loses access to a folder chosen in an open panel when it quits.
/// The folder is therefore stored as an app-scoped security-scoped bookmark next to
/// its path. The path remains the displayed value and the fallback when no bookmark
/// exists or it can no longer be resolved, so unsandboxed builds and preferences
/// saved before the sandbox keep their previous behavior.
public enum SecurityScopedFolder {
  /// Creates an app-scoped security-scoped bookmark for a folder the user selected.
  /// Returns nil when the system cannot create one; callers keep the plain path.
  public static func bookmark(for url: URL) -> Data? {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    return try? url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  /// Returns the folder for a stored bookmark, falling back to the stored path.
  ///
  /// A resolved folder stays accessible for the rest of the process lifetime;
  /// recordings and screenshots write to it at arbitrary times after resolution.
  public static func url(path: String?, bookmark: Data?) -> URL? {
    if let bookmark, let url = access.url(resolving: bookmark) { return url }
    guard let path, !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private static let access = ProcessLifetimeAccess()

  /// Starts access to each distinct bookmark at most once per process, so repeated
  /// resolution does not accumulate unbalanced security-scope references.
  private final class ProcessLifetimeAccess: Sendable {
    private let resolvedURLs = OSAllocatedUnfairLock<[Data: URL]>(initialState: [:])

    func url(resolving bookmark: Data) -> URL? {
      resolvedURLs.withLock { resolvedURLs in
        if let url = resolvedURLs[bookmark] { return url }
        var isStale = false
        guard
          let url = try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        resolvedURLs[bookmark] = url
        return url
      }
    }
  }
}
