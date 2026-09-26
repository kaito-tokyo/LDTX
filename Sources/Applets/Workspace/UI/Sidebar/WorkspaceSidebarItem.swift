// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import Foundation

public enum WorkspaceSidebarItem: Equatable, Hashable {
  case preview
  case output
  case canvas
  case videoLayers
  case programs
  case inputDevice(Ldtx_Workspace_V4_InputDeviceWrapper)
  case programInputDevice(String)
  case vision(Ldtx_Workspace_V4_VisionWrapper)
  case videoComponent(Ldtx_Workspace_V4_VideoComponentWrapper)
}
