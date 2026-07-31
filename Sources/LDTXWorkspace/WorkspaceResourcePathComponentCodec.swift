// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Converts a Workspace resource name into one reversible filesystem path component.
public enum WorkspaceResourcePathComponentCodec {
    public static func encode(_ name: String) -> String {
        name
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ".", with: "%2E")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "\0", with: "%00")
    }
}
