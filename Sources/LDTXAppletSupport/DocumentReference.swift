// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
public final class DocumentReference {
  public private(set) weak var document: NSDocument?

  public init(_ document: NSDocument) {
    self.document = document
  }
}

extension EnvironmentValues {
  @Entry public var documentReference: DocumentReference? = nil
}
