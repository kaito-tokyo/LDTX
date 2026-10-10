// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension EnvironmentValues {
  @Entry public var workspaceReportError: (Error) -> Void = { _ in }
}
