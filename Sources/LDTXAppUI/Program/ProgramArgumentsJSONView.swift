// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct ProgramArgumentsJSONView: View {
    private var jsonText: String

    public init(jsonText: String) {
        self.jsonText = jsonText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ProgramArguments JSON")
                .font(.headline)

            ScrollView {
                Text(jsonText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minWidth: 520, minHeight: 420)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
    }
}

#if DEBUG
#Preview("ProgramArguments JSON") {
    ProgramArgumentsJSONView(
        jsonText: """
        {
          "audioChannelGainsByName" : {
            "Mic" : 1,
            "System Audio" : 0.7079457843841379,
            "Guest" : 0.5011872336272722
          }
        }
        """
    )
}
#endif
