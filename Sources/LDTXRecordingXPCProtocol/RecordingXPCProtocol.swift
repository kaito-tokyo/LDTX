// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

@objc public protocol LDTXRecordingWriterServiceXPC {
  func configureMain(
    _ request: Data,
    videoRingFileHandle: FileHandle,
    audioRingFileHandle: FileHandle,
    outputFileHandle: FileHandle,
    withReply reply: @escaping (Data) -> Void
  )
  func drainMainRings(withReply reply: @escaping (Data) -> Void)
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol LDTXRecordingWriterClientXPC {
  func recordingWriterEvent(_ event: Data)
}

public enum LDTXRecordingWriterXPCInterfaces {
  public static let protocolVersion: UInt32 = 3

  public static func service() -> NSXPCInterface {
    NSXPCInterface(with: LDTXRecordingWriterServiceXPC.self)
  }

  public static func client() -> NSXPCInterface {
    NSXPCInterface(with: LDTXRecordingWriterClientXPC.self)
  }
}
