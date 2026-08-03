// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

/// The facts that describe a Workspace window's current lifetime.
///
/// Views use these facts to decide whether controls for the data they own are
/// editable. This type deliberately does not centralize action permissions.
public struct WorkspaceWindowState: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case edit
    case output
  }

  public let mode: Mode
  public let outputSessionState: OutputSessionControlState
  public let activeOutputMode: CaptureOutputMode?
  public let isRecordFinalizing: Bool
  public let isRecordCutCoolingDown: Bool
  public let isProgramRuntimeTransitioning: Bool
  public let isOperationLocked: Bool

  public init(
    mode: Mode,
    outputSessionState: OutputSessionControlState,
    activeOutputMode: CaptureOutputMode? = nil,
    isRecordFinalizing: Bool = false,
    isRecordCutCoolingDown: Bool = false,
    isProgramRuntimeTransitioning: Bool = false,
    isOperationLocked: Bool
  ) {
    self.mode = mode
    self.outputSessionState = outputSessionState
    self.activeOutputMode = activeOutputMode
    self.isRecordFinalizing = isRecordFinalizing
    self.isRecordCutCoolingDown = isRecordCutCoolingDown
    self.isProgramRuntimeTransitioning = isProgramRuntimeTransitioning
    self.isOperationLocked = isOperationLocked
  }
}
