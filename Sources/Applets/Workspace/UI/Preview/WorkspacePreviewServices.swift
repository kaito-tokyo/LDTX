// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#if DEBUG
  import LDTXCorelibs
  import LDTXWorkspaceAppletInterface
  import Observation

  @MainActor @Observable
  final class PreviewDeviceRegistry: WorkspaceDeviceRegistry {
    var cameras: [CameraCaptureSource] = []
    var audioInputDevices: [AudioInputDevice] = []
    var error: (any Error)?
    var errorMessage: String? { error?.localizedDescription }
    var hasRefreshed = false
    func refresh(reportErrors: Bool) { hasRefreshed = true }
  }
#endif
