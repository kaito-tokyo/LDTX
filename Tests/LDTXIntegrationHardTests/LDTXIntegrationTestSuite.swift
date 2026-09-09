// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

/// Cross-component tests whose AVFoundation and persistence resources must not
/// overlap each other.
@Suite(.serialized)
struct LDTXIntegrationTestSuite {}
