// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import Testing

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

private let secretPath = "/Users/fixture-user/Secret Recordings/stream-key-abc123"

private enum FixtureError: Error, LocalizedError {
  case plain
  case folderUnavailable(path: String)
  case wrapped(any Error)

  var errorDescription: String? { "Fixture failed at \(secretPath)" }
}

private struct DescribedError: Error, CustomStringConvertible {
  var description: String { secretPath }
}

private enum DescribedEnumError: Error, CustomStringConvertible {
  case leaking
  var description: String { secretPath }
}

private enum PhaseError: Error, PublicErrorDiagnosticDetailProviding {
  case protocolFailure(String)
  var publicDiagnosticDetail: String? {
    switch self {
    case .protocolFailure(let phase): phase
    }
  }
}

@Suite
struct PublicErrorDiagnosticUnitTestSuite {
  @Test("LUB-1074: Swift error cases are named without associated values")
  func swiftErrorCasesAreNamedWithoutAssociatedValues() {
    let plain = PublicErrorDiagnostic(FixtureError.plain)
    let payload = PublicErrorDiagnostic(FixtureError.folderUnavailable(path: secretPath))

    #expect(plain.typeName.hasSuffix("FixtureError"))
    #expect(!plain.typeName.contains("unknown context"))
    #expect(plain.caseName == "plain")
    #expect(plain.domain == nil)
    #expect(payload.caseName == "folderUnavailable")
    #expect(!payload.description.contains("fixture-user"))
    #expect(payload.description.contains("case=folderUnavailable"))
  }

  @Test("LUB-1074: Custom descriptions never reach the public diagnostic")
  func customDescriptionsNeverReachThePublicDiagnostic() {
    for error in [DescribedError() as any Error, DescribedEnumError.leaking] {
      let diagnostic = PublicErrorDiagnostic(error)

      #expect(diagnostic.caseName == nil)
      #expect(!diagnostic.description.contains("fixture-user"))
    }
  }

  @Test("LUB-1074: Underlying errors are summarized recursively")
  func underlyingErrorsAreSummarizedRecursively() {
    let diagnostic = PublicErrorDiagnostic(FixtureError.wrapped(FixtureError.plain))

    #expect(diagnostic.caseName == "wrapped")
    #expect(diagnostic.underlying.map(\.caseName) == ["plain"])
  }

  @Test("LUB-1074: Implementation details are public only as identifiers")
  func implementationDetailsArePublicOnlyAsIdentifiers() {
    #expect(PublicErrorDiagnostic(PhaseError.protocolFailure("handshake")).detail == "handshake")
    #expect(PublicErrorDiagnostic(PhaseError.protocolFailure(secretPath)).detail == nil)
  }

  #if canImport(Darwin)
    @Test("LUB-1074: System domains are public and other domains are redacted")
    func systemDomainsArePublicAndOtherDomainsAreRedacted() {
      let underlying = NSError(
        domain: NSPOSIXErrorDomain, code: 1, userInfo: [NSFilePathErrorKey: secretPath])
      let system = PublicErrorDiagnostic(
        NSError(
          domain: NSCocoaErrorDomain, code: 513,
          userInfo: [NSUnderlyingErrorKey: underlying, NSFilePathErrorKey: secretPath]))
      let server = PublicErrorDiagnostic(
        NSError(
          domain: "server says \(secretPath)", code: 7,
          userInfo: [NSLocalizedDescriptionKey: secretPath]))

      #expect(system.domain == NSCocoaErrorDomain)
      #expect(system.code == 513)
      #expect(system.underlying.map(\.domain) == [NSPOSIXErrorDomain])
      #expect(system.underlying.map(\.code) == [1])
      #expect(server.domain == PublicErrorDiagnostic.redactedDomain)
      #expect(server.code == 7)
      for diagnostic in [system, server] {
        #expect(!diagnostic.description.contains("fixture-user"))
      }
    }

    @Test("LUB-1074: Bridged Swift errors keep their type name")
    func bridgedSwiftErrorsKeepTheirTypeName() {
      let bridged = FixtureError.folderUnavailable(path: secretPath) as NSError
      let wrapper = NSError(
        domain: "WorkspaceOutput", code: 1, userInfo: [NSUnderlyingErrorKey: bridged])

      let diagnostic = PublicErrorDiagnostic(bridged)
      let wrapped = PublicErrorDiagnostic(wrapper)

      #expect(diagnostic.typeName.hasSuffix("FixtureError"))
      #expect(!diagnostic.typeName.contains("unknown context"))
      #expect(diagnostic.domain == nil)
      #expect(
        diagnostic.code == PublicErrorDiagnostic(FixtureError.folderUnavailable(path: "")).code)
      #expect(wrapped.domain == "WorkspaceOutput")
      #expect(wrapped.underlying.first?.typeName.hasSuffix("FixtureError") == true)
      #expect(!wrapped.description.contains("fixture-user"))
    }
  #endif
}
