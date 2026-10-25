// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RecordingCustomFieldsFile {
  public static func write(_ fields: [String: String], to packageDirectory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(fields).write(
      to: packageDirectory.appendingPathComponent(RecordingPackage.customFieldsFileName),
      options: .atomic)
  }
}
