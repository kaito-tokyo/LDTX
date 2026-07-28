// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum NotoSansFontResources {
  static let bundledUprightVariableFontURL = resourceURLIfAvailable(
    named: "NotoSans[wght]",
    extension: "ttf"
  )

  public static var uprightVariableFontURL: URL {
    requiredResourceURL(
      bundledUprightVariableFontURL,
      named: "NotoSans[wght]",
      extension: "ttf"
    )
  }

  public static let italicVariableFontURL = resourceURL(
    named: "NotoSans-Italic[wght]", extension: "ttf")
  public static let openFontLicenseURL = resourceURL(named: "OFL", extension: "txt")

  private static func resourceURLIfAvailable(
    named name: String,
    extension fileExtension: String
  ) -> URL? {
    Bundle.module.url(
      forResource: name,
      withExtension: fileExtension,
      subdirectory: "NotoSans"
    )
  }

  private static func resourceURL(named name: String, extension fileExtension: String) -> URL {
    requiredResourceURL(
      resourceURLIfAvailable(named: name, extension: fileExtension),
      named: name,
      extension: fileExtension
    )
  }

  private static func requiredResourceURL(
    _ url: URL?,
    named name: String,
    extension fileExtension: String
  ) -> URL {
    guard let url else {
      preconditionFailure("Missing bundled Noto Sans resource: \(name).\(fileExtension)")
    }
    return url
  }
}
