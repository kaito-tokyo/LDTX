// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension Ldtx_Envelope_WorkspaceDefinitionEnvelope {
  public var externalIDAsUUID: UUID? {
    UUID(uuidString: externalID)
  }
}

extension Ldtx_Envelope_WorkspacePreferencesEnvelope {
  public var externalIDAsUUID: UUID? {
    UUID(uuidString: externalID)
  }
}
