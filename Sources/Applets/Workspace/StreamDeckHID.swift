// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import os

/// IOKit objects, callback buffer, image encoding and transfers are confined to
/// one worker thread. Only the bounded latest-frame mailbox crosses threads.
final class StreamDeckHID: @unchecked Sendable {
  private struct Mailbox {
    var generation: UInt64 = 0
    var stopped = false
    var frame = StreamDeckFrame()
  }
  private let mailbox = Mutex(Mailbox())
  private let completion = DispatchGroup()
  private let onPress: @Sendable (Int, StreamDeckFrame, UInt64) -> Void
  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "StreamDeck")
  private var device: IOHIDDevice?
  private var report = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
  private var pressState = StreamDeckPressState()
  private var displayedGeneration: UInt64 = 0
  private var displayed: StreamDeckFrame?
  private var images: [String: Data] = [:]

  init(onPress: @escaping @Sendable (Int, StreamDeckFrame, UInt64) -> Void) {
    self.onPress = onPress
  }

  deinit { report.deallocate() }

  func update(_ frame: StreamDeckFrame) {
    mailbox.withLock {
      if $0.frame != frame {
        $0.generation &+= 1
        $0.frame = frame
      }
    }
  }
  func isCurrent(_ generation: UInt64) -> Bool {
    mailbox.withLock { !$0.stopped && $0.generation == generation }
  }
  func stop() {
    mailbox.withLock { $0.stopped = true }
    // The worker never waits on MainActor, so termination can drain it here.
    completion.wait()
  }
  func start() {
    completion.enter()
    Thread.detachNewThread { [self] in
      defer { completion.leave() }
      run()
    }
  }

  private func run() {
    // The manager discovers devices; this worker owns each device's scheduling
    // and exclusive open independently of manager scheduling and teardown.
    let manager = IOHIDManagerCreate(
      kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
    IOHIDManagerSetDeviceMatching(
      manager,
      [
        kIOHIDVendorIDKey: 0x0fd9, kIOHIDProductIDKey: 0x0080,
      ] as CFDictionary)
    // Leave the manager's device-level removal callback intact so its
    // enumeration set drops unplugged devices before discovery runs again.
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      { context, _, _, removed in
        guard let context else { return }
        let worker = Unmanaged<StreamDeckHID>.fromOpaque(context).takeUnretainedValue()
        if worker.device == removed { worker.disconnect() }
      }, Unmanaged.passUnretained(self).toOpaque())
    // Discovery does not open every device. Seize only a single unambiguous MK.2.
    IOHIDManagerScheduleWithRunLoop(
      manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    defer {
      disconnect()
      IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    var nextDiscovery = Date.distantPast
    while !mailbox.withLock({ $0.stopped }) {
      autoreleasepool {
        if Date() >= nextDiscovery {
          discover(manager)
          nextDiscovery = Date().addingTimeInterval(1)
        }
        let (frame, generation) = mailbox.withLock { ($0.frame, $0.generation) }
        if let device, displayed != frame || displayedGeneration != generation {
          let old = displayed
          var succeeded = true
          // Clear unused keys once on attachment; never leave another app's actions visible.
          for key in 0..<15 {
            let symbolName =
              key == 0
              ? "stop.fill"
              : key == 1
                ? (frame.pause ? "pause.fill" : "play.fill")
                : key == 2 ? "camera" : ""
            let enabled = key < 3 && frame.enabled[key]
            if old != nil, key >= 3 { continue }
            if let old, key < 3, old.enabled[key] == enabled,
              key != 1 || old.pause == frame.pause
            {
              continue
            }
            guard let image = image(symbolName: symbolName, enabled: enabled),
              upload(image, key: key, to: device)
            else {
              succeeded = false
              break
            }
          }
          if succeeded {
            displayedGeneration = generation
            displayed = frame
            if old == nil { logger.notice("Stream Deck fixed key layout uploaded") }
          } else {
            disconnect()
          }
        }
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
      }
    }
  }

  private func discover(_ manager: IOHIDManager) {
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    guard devices.count == 1, let candidate = devices.first else {
      if device != nil { logger.notice("Stream Deck disconnected or selection is ambiguous") }
      disconnect()
      return
    }
    if let device, device == candidate { return }
    disconnect()
    let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    guard result == kIOReturnSuccess else {
      logger.debug("Stream Deck unavailable (busy or permission denied): \(result)")
      return
    }
    device = candidate
    // Set maximum backlight brightness on every successful attachment.
    var brightness: [UInt8] = [0x03, 0x08, 100] + Array(repeating: 0, count: 29)
    let brightnessResult = IOHIDDeviceSetReport(
      candidate, kIOHIDReportTypeFeature, 0x03, &brightness, brightness.count)
    if brightnessResult != kIOReturnSuccess {
      logger.error("Stream Deck brightness setting failed: \(brightnessResult)")
    }
    // Seed held-state before accepting edges when GET_REPORT is supported.
    var initial = [UInt8](repeating: 0, count: 1024)
    initial[0] = 0x01
    var length = initial.count
    if IOHIDDeviceGetReport(candidate, kIOHIDReportTypeInput, 0x01, &initial, &length)
      == kIOReturnSuccess
    {
      _ = pressState.receive(Array(initial.prefix(length)))
    }
    IOHIDDeviceRegisterInputReportCallback(
      candidate, report, 1024,
      { context, result, _, _, _, bytes, count in
        guard let context, result == kIOReturnSuccess else { return }
        Unmanaged<StreamDeckHID>.fromOpaque(context).takeUnretainedValue().received(
          bytes, count: count)
      }, Unmanaged.passUnretained(self).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(
      candidate, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    logger.notice("Stream Deck MK.2 connected")
  }

  private func disconnect() {
    guard let device else { return }
    IOHIDDeviceRegisterInputReportCallback(device, report, 1024, nil, nil)
    IOHIDDeviceUnscheduleFromRunLoop(
      device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    // Restore the device logo only while we still own the exclusive connection.
    var reset: [UInt8] = [0x03, 0x02] + Array(repeating: 0, count: 30)
    _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x03, &reset, reset.count)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    mailbox.withLock { $0.generation &+= 1 }
    self.device = nil
    pressState = StreamDeckPressState()
    displayed = nil
  }

  private func received(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) {
    let edges = pressState.receive(Array(UnsafeBufferPointer(start: bytes, count: count)))
    guard let displayed, isCurrent(displayedGeneration) else { return }
    for key in edges where displayed.enabled[key] {
      onPress(key, displayed, displayedGeneration)
      break
    }
  }

  private func upload(_ image: Data, key: Int, to device: IOHIDDevice) -> Bool {
    var offset = 0
    let imageBytes = Array(image)
    while offset < image.count {
      if mailbox.withLock({ $0.stopped }) { return false }
      let size = min(1016, image.count - offset)
      var bytes = StreamDeckImageReport.make(image: imageBytes, key: key, offset: offset)
      let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x02, &bytes, bytes.count)
      guard result == kIOReturnSuccess else {
        logger.error("Stream Deck image transfer failed: \(result)")
        return false
      }
      offset += size
    }
    return true
  }

  private func image(symbolName: String, enabled: Bool) -> Data? {
    let cacheKey = "\(symbolName)-\(enabled)"
    if let cached = images[cacheKey] { return cached }
    guard
      let context = CGContext(
        data: nil, width: 72, height: 72, bitsPerComponent: 8,
        bytesPerRow: 72 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 72, height: 72))
    // MK.2 JPEG orientation is 180 degrees, as in the upstream model.
    context.translateBy(x: 72, y: 72)
    context.rotate(by: .pi)
    if !symbolName.isEmpty {
      guard
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(pointSize: 48, weight: .semibold)),
        let mask = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { return nil }
      let scale = 48 / CGFloat(max(mask.width, mask.height))
      let width = CGFloat(mask.width) * scale
      let height = CGFloat(mask.height) * scale
      let rect = CGRect(x: (72 - width) / 2, y: (72 - height) / 2, width: width, height: height)
      let color: NSColor =
        switch (enabled, symbolName) {
        case (false, _): .white
        case (true, "stop.fill"): .systemRed
        case (true, "play.fill"): .systemGreen
        case (true, "pause.fill"): .systemOrange
        default: .systemBlue
        }
      guard let rgbColor = color.usingColorSpace(.deviceRGB) else { return nil }
      context.saveGState()
      context.clip(to: rect, mask: mask)
      context.setFillColor(rgbColor.cgColor)
      context.fill(rect)
      context.restoreGState()
      if !enabled {
        // A black outline keeps the slash distinct over a filled white symbol.
        context.setLineCap(.round)
        for (color, width) in [
          (CGColor(gray: 0, alpha: 1), 7.0),
          (CGColor(gray: 1, alpha: 1), 3.0),
        ] {
          context.setStrokeColor(color)
          context.setLineWidth(width)
          context.move(to: CGPoint(x: 10, y: 10))
          context.addLine(to: CGPoint(x: 62, y: 62))
          context.strokePath()
        }
      }
    }
    guard let cgImage = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    let result = data as Data
    images[cacheKey] = result
    return result
  }
}
