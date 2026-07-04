// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if arch(x86_64)
// LDTXCore is arm64-only at runtime. Xcode may still type-check a local
// Swift package as x86_64 before the app target filters architectures.
public typealias Float16 = Float
#endif
