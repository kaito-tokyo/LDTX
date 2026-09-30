// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum WorkspaceRecordingState: Equatable {
  case idle
  case starting
  case recording
  case stopping
  case failed(String)
}
