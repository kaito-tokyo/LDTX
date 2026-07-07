// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceSidebarItem: Equatable, Hashable {
    case inputDevice(String)
    case videoComponent(UUID)
}
