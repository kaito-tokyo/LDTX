// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAudioKit

private struct Options {
  var duration: Double?
  var output: String?
  var inputUID: String?
  var sampleRate = 48_000.0
  var channels: UInt32 = 2
  var json = false
}

private enum CommandError: Error, LocalizedError {
  case invalidArguments(String)
  var errorDescription: String? {
    if case .invalidArguments(let message) = self { return message }
    return nil
  }
}

private func usage() {
  print("Usage: ldtx-track-record --duration <seconds> --output <path> [options]")
  print("Options: --input-uid <uid> --sample-rate <rate> --channels <count> --json")
}

private func parse(_ arguments: [String]) throws -> Options? {
  var result = Options()
  var values: Set<String> = []
  var index = 0
  while index < arguments.count {
    let argument = arguments[index]
    if argument == "--help" || argument == "-h" { usage(); return nil }
    if argument == "--json" {
      guard values.insert(argument).inserted else { throw CommandError.invalidArguments("Duplicate option: \(argument)") }
      result.json = true
      index += 1
      continue
    }
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    let key = parts[0]
    let value: String
    if parts.count == 2 {
      value = parts[1]
    } else {
      index += 1
      guard index < arguments.count, !arguments[index].hasPrefix("--") else {
        throw CommandError.invalidArguments("Missing value for \(key)")
      }
      value = arguments[index]
    }
    guard values.insert(key).inserted else { throw CommandError.invalidArguments("Duplicate option: \(key)") }
    switch key {
    case "--duration": result.duration = Double(value)
    case "--output": result.output = value
    case "--input-uid": result.inputUID = value
    case "--sample-rate": result.sampleRate = Double(value) ?? 0
    case "--channels": result.channels = UInt32(value) ?? 0
    default: throw CommandError.invalidArguments("Unknown option: \(key)")
    }
    index += 1
  }
  guard let duration = result.duration, duration > 0, let output = result.output, !output.isEmpty,
    result.sampleRate > 0, result.channels > 0
  else { throw CommandError.invalidArguments("--duration and --output are required") }
  _ = duration
  return result
}

@main
struct LDTXCmdTrackRecord {
  static func main() async {
    do {
      guard let options = try parse(Array(CommandLine.arguments.dropFirst())) else { return }
      guard let duration = options.duration, let output = options.output else { throw CommandError.invalidArguments("Missing options") }
      guard let uid = options.inputUID ?? AudioEngine.defaultInputUID() else {
        Foundation.exit(3)
      }
      let engine = AudioEngine(hardwareEnabled: true)
      let recorder = try AudioTrackRecorder(
        engine: engine, inputUID: uid, outputURL: URL(fileURLWithPath: output),
        sampleRate: options.sampleRate, channels: options.channels)
      let result = try await recorder.record(for: .seconds(duration))
      if options.json {
        let object: [String: Any] = [
          "inputUID": result.inputUID, "sampleRate": result.sampleRate,
          "channels": result.channels, "receivedFrames": result.receivedFrames,
          "output": result.outputURL.path, "status": "ok"
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
      } else {
        print("Recorded \(result.receivedFrames) frames to \(result.outputURL.path)")
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      Foundation.exit(2)
    }
  }
}
