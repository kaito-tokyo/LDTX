// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

/// Coordinates integration suites that exercise AVAssetWriter's shared
/// process-wide lifecycle gate and segment delegate.
@Suite(.serialized)
struct AVAssetWriterLifecycleIntegrationTestSuite {}
