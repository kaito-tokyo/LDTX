// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_Rational32 {
  public var float: Float {
    Float(double)
  }

  public var double: Double {
    Double(numerator) / Double(denominator)
  }
}
