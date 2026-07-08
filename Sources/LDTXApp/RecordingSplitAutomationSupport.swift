// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI

enum RecordingSplitAutomationSupport {
    static func validationFailure(
        isOutputSessionRunning: Bool,
        activeCaptureOutputMode: CaptureOutputMode?
    ) -> AppAutomationCommandResult? {
        guard isOutputSessionRunning else {
            return AppAutomationCommandResult(ok: false, message: "Recording is not running.")
        }
        switch activeCaptureOutputMode {
        case .record, .youtubeAndRecord:
            return nil
        case .youtube:
            return AppAutomationCommandResult(
                ok: false,
                message: "Recording split is only available for record or youtubeAndRecord output."
            )
        case nil:
            return AppAutomationCommandResult(ok: false, message: "Recording is not running.")
        }
    }
}
