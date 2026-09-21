
func applicationDidFinishLaunching(_ notification: Notification) {
    launch()
    showLauncherIfNeeded()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.isFileURL {
      let url = url.standardizedFileURL
      switch url.pathExtension.lowercased() {
      case WorkspacePackageLayout.pathExtension:
        WorkspaceApplet.open(url: url) { [weak self] applet, _ in
          guard let applet else {
            self?.showLauncherIfNeeded()
            return
          }
          applet.windowController?.showWindow(nil)
          applet.makeKeyAndOrderFront(nil)
          self?.launcher?.close()
        }
      case RecordingPackage.pathExtension:
        RecordPlayerApplet.open(
          recordingURL: url) { [weak self] applet, _ in
          guard let applet else {
            self?.showLauncherIfNeeded()
            return
          }
          applet.windowController?.showWindow(nil)
          applet.makeKeyAndOrderFront(nil)
          self?.launcher?.close()
        }
      default:
        continue
      }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showLauncher() }
    return true
  }

  private func terminate(reply: @escaping (Bool) -> Void) {
    guard !isTerminating else { reply(false); return }
    isTerminating = true
    var workspaces: [WorkspaceApplet] = []
    for window in NSApp.windows {
      guard let workspace = window.windowController as? WorkspaceApplet else { continue }
      workspaces.append(workspace)
    }
    let participants = workspaces.map { controller in
      (
        confirm: { controller.confirmTermination() },
        cancel: { controller.cancelTerminationConfirmation() },
        stop: { await controller.closeWorkspace() }
      )
    }
    Task { @MainActor in
      guard participants.allSatisfy({ $0.confirm() }) else {
        for participant in participants { participant.cancel() }
        isTerminating = false
        reply(false)
        return
      }
      for participant in participants { await participant.stop() }
      isTerminating = false
      reply(true)
    }
  }

  private var activeWorkspace: WorkspaceApplet? {
    NSApp.keyWindow?.windowController as? WorkspaceApplet
  }
}
