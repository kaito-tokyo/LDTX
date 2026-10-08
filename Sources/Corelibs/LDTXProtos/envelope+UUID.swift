// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

private func uuidData(_ uuid: UUID) -> Data {
  var bytes = uuid.uuid
  return withUnsafeBytes(of: &bytes) { Data($0) }
}

private func uuidFromData(_ data: Data) -> UUID? {
  guard data.count == 16 else { return nil }
  let bytes = Array(data)
  return UUID(uuid: (
    bytes[0], bytes[1], bytes[2], bytes[3],
    bytes[4], bytes[5], bytes[6], bytes[7],
    bytes[8], bytes[9], bytes[10], bytes[11],
    bytes[12], bytes[13], bytes[14], bytes[15]))
}

extension Ldtx_Envelope_WorkspaceDefinitionEnvelope {
  public var externalIDAsUUID: UUID? {
    get { uuidFromData(externalID) }
    set {
      if let newValue { externalID = uuidData(newValue) }
      else { clearExternalID() }
    }
  }
}

extension Ldtx_Envelope_WorkspacePreferencesEnvelope {
  public var externalIDAsUUID: UUID? {
    get { uuidFromData(externalID) }
    set {
      if let newValue { externalID = uuidData(newValue) }
      else { clearExternalID() }
    }
  }
}

extension Ldtx_Envelope_WorkspaceOutputSettingsEnvelope {
  public var externalIDAsUUID: UUID? {
    get { uuidFromData(externalID) }
    set {
      if let newValue { externalID = uuidData(newValue) }
      else { clearExternalID() }
    }
  }
}
