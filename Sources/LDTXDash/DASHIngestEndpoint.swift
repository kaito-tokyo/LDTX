// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DASHIngestEndpoint: Sendable, Equatable {
  public let baseURL: URL

  public init(baseURL: URL) {
    self.baseURL = baseURL
  }

  public func url(for objectName: DASHObjectName) -> URL {
    if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      var queryItems = components.queryItems,
      let fileIndex = queryItems.firstIndex(where: { $0.name == "file" })
    {
      let prefix = queryItems[fileIndex].value ?? ""
      queryItems[fileIndex].value = prefix + objectName.rawValue
      components.queryItems = queryItems
      if let url = components.url {
        return url
      }
    }

    let absolute = baseURL.absoluteString
    if absolute.hasSuffix("/") {
      return URL(string: absolute + objectName.rawValue)!
    }

    return baseURL.appendingPathComponent(objectName.rawValue)
  }

  public func mpdReference(for objectNameTemplate: String) -> String {
    let absolute = baseURL.absoluteString
    let fullReference: String
    if absolute.hasSuffix("/") || absolute.hasSuffix("=") {
      fullReference = absolute + objectNameTemplate
    } else {
      fullReference = baseURL.appendingPathComponent(objectNameTemplate).absoluteString
    }

    guard let schemeRange = fullReference.range(of: "://") else {
      return fullReference
    }

    let afterScheme = fullReference[schemeRange.upperBound...]
    guard let pathStart = afterScheme.firstIndex(of: "/") else {
      return fullReference
    }

    return String(afterScheme[pathStart...])
  }
}
