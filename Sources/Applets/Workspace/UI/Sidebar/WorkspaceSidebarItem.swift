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
  case inputDevice(String)
  case vision(String)
  case videoComponent(String)
}
