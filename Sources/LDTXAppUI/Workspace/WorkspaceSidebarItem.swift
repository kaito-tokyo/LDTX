// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceSidebarItem: Equatable, Hashable {
    case output
    case canvas
    case inputDevice(String)
    case vision(String)
    case videoComponent(String)
}
