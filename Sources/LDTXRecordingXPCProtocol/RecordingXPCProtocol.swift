// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

@objc public protocol LDTXRecordingWriterServiceXPC {
  func configure(
    _ request: Data,
    ringFileHandle: FileHandle,
    outputFileHandle: FileHandle,
    withReply reply: @escaping (Data) -> Void
  )
  func drainRing(withReply reply: @escaping (Data) -> Void)
  func prepareCut(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func commitCut(
    _ request: Data,
    outputFileHandle: FileHandle,
    withReply reply: @escaping (Data) -> Void
  )
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func abort(_ request: Data)
  func status(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol LDTXRecordingWriterClientXPC {
  func recordingWriterEvent(_ event: Data)
}

public enum LDTXRecordingWriterXPCInterfaces {
  public static let protocolVersion: UInt32 = 2

  public static func service() -> NSXPCInterface {
    NSXPCInterface(with: LDTXRecordingWriterServiceXPC.self)
  }

  public static func client() -> NSXPCInterface {
    NSXPCInterface(with: LDTXRecordingWriterClientXPC.self)
  }
}
