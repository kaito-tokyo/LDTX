// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Supplies a fixed, implementation-defined detail for an error's public diagnostic.
///
/// Return only identifiers chosen by the implementation, such as a protocol phase.
/// Never return paths, URLs, credentials, server text or authored content; values
/// that are not short identifiers are dropped.
public protocol PublicErrorDiagnosticDetailProviding {
  var publicDiagnosticDetail: String? { get }
}

/// A description of an error that is safe to interpolate into public logs.
///
/// It contains only values fixed by code: the Swift type name, the enum case name,
/// an opt-in implementation detail, the numeric code, allowlisted system or LDTX
/// error domains, and the same summary of underlying errors. Associated values,
/// localized descriptions, user-info strings and other domains are never included,
/// so they can contain paths, URLs, stream keys, tokens or server text without
/// reaching the log. Use `privacy: .public` for `description`.
public struct PublicErrorDiagnostic: Sendable, Equatable, CustomStringConvertible {
  /// Replaces a domain that is not known to be fixed by code.
  public static let redactedDomain = "<redacted>"

  public let typeName: String
  public let caseName: String?
  public let detail: String?
  /// Nil for Swift errors, whose domain repeats the type name.
  public let domain: String?
  public let code: Int
  public let underlying: [PublicErrorDiagnostic]

  private static let maximumDepth = 4
  private static let maximumUnderlyingCount = 4

  public init(_ error: any Error) {
    self.init(error, depth: 0)
  }

  private init(_ error: any Error, depth: Int) {
    let nested = depth < Self.maximumDepth
    detail = (error as? any PublicErrorDiagnosticDetailProviding)?.publicDiagnosticDetail
      .flatMap { Self.isIdentifier($0, allowing: "_.-") ? $0 : nil }
    #if canImport(Darwin)
      let nsError = error as NSError
      code = nsError.code
      if type(of: error) is NSError.Type {
        caseName = nil
        underlying = nested ? Self.underlyingErrors(of: nsError, depth: depth) : []
        if Self.isBridgedSwiftError(nsError) {
          // A boxed Swift error's domain is its qualified type name.
          typeName = Self.sanitizedTypeName(nsError.domain)
          domain = nil
        } else {
          typeName = Self.sanitizedTypeName(String(reflecting: type(of: error)))
          domain = Self.publicDomain(nsError.domain)
        }
        return
      }
    #else
      code = error._code
    #endif
    typeName = Self.sanitizedTypeName(String(reflecting: type(of: error)))
    domain = nil
    let mirror = Mirror(reflecting: error)
    caseName = mirror.displayStyle == .enum ? Self.caseName(of: error, mirror: mirror) : nil
    underlying = nested ? Self.payloadErrors(of: mirror, depth: depth) : []
  }

  public var description: String {
    var fields = ["type=\(typeName)"]
    if let caseName { fields.append("case=\(caseName)") }
    if let detail { fields.append("detail=\(detail)") }
    if let domain { fields.append("domain=\(domain)") }
    fields.append("code=\(code)")
    if !underlying.isEmpty {
      fields.append("underlying=[\(underlying.map(\.description).joined(separator: "; "))]")
    }
    return fields.joined(separator: " ")
  }

  // MARK: - Type and case

  private static func sanitizedTypeName(_ reflectedName: String) -> String {
    var name = reflectedName
    // Private and local types carry an address-like context that varies per build.
    while let start = name.range(of: "(unknown context at "),
      let end = name.range(of: ").", range: start.upperBound..<name.endIndex)
    {
      name.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return isIdentifier(name, allowing: "_.<>, ") ? name : "<unknown>"
  }

  private static func caseName(of error: any Error, mirror: Mirror) -> String? {
    if let label = mirror.children.first?.label {
      return isIdentifier(label, allowing: "_") ? label : nil
    }
    // A payload-free case describes itself by name unless a custom description
    // replaces it; custom descriptions are not known to be public.
    guard !(error is any CustomStringConvertible), !(error is any CustomDebugStringConvertible),
      !(error is any TextOutputStreamable)
    else { return nil }
    let name = String(describing: error)
    return isIdentifier(name, allowing: "_") ? name : nil
  }

  private static func payloadErrors(of mirror: Mirror, depth: Int) -> [PublicErrorDiagnostic] {
    guard let payload = mirror.children.first?.value else { return [] }
    let values: [Any]
    if let error = payload as? any Error {
      values = [error]
    } else {
      values = Mirror(reflecting: payload).children.map(\.value)
    }
    return values.lazy.compactMap { $0 as? any Error }.prefix(maximumUnderlyingCount)
      .map { PublicErrorDiagnostic($0, depth: depth + 1) }
  }

  private static func isIdentifier(_ value: String, allowing extra: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 160 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      (scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)))
        || extra.unicodeScalars.contains(scalar)
    }
  }

  // MARK: - NSError

  #if canImport(Darwin)
    /// Domains whose names are fixed by Apple frameworks or by LDTX code.
    private static let publicDomains: Set<String> = [
      NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
      NSMachErrorDomain, "AVFoundationErrorDomain", "NSItemProviderErrorDomain",
      "WorkspaceOutput", "WorkspaceProgramSelection", "WorkspaceRecordingCut",
      "WorkspaceRuntime", "WorkspaceClose", "WorkspaceScreenshot", "WorkspaceProgramDeletion",
      "WorkspaceDeviceAssignment", "VisionArchive",
    ]
    private static let publicDomainPrefixes = [
      "com.apple.", "kCFErrorDomain", "kNWErrorDomain", "tokyo.kaito.ldtx.",
    ]

    private static func publicDomain(_ domain: String) -> String {
      let isPublic =
        publicDomains.contains(domain)
        || publicDomainPrefixes.contains { domain.hasPrefix($0) }
      return isPublic && isIdentifier(domain, allowing: "_.-") ? domain : redactedDomain
    }

    private static func isBridgedSwiftError(_ error: NSError) -> Bool {
      NSStringFromClass(type(of: error)).hasSuffix("SwiftNativeNSError")
    }

    private static func underlyingErrors(
      of error: NSError, depth: Int
    ) -> [PublicErrorDiagnostic] {
      var errors: [any Error] = []
      if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
        errors.append(underlying)
      }
      if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
        errors.append(contentsOf: multiple)
      }
      return errors.prefix(maximumUnderlyingCount).map {
        PublicErrorDiagnostic($0, depth: depth + 1)
      }
    }
  #endif
}
