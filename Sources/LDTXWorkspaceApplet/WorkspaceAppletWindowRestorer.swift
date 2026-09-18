import AppKit
import Foundation

@MainActor
public final class WorkspaceAppletWindowRestorer: NSObject, NSWindowRestoration {
  public static var openWorkspace: ((URL) -> NSWindow?)?

  public static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier,
    state: NSCoder,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    guard
      let url = state.decodeObject(of: NSURL.self, forKey: "LDTX.AppKit.v1.url") as URL?,
      FileManager.default.fileExists(atPath: url.path)
    else {
      completionHandler(nil, nil)
      return
    }
    let window = openWorkspace?(url)
    window?.identifier = identifier
    completionHandler(window, nil)
  }
}
