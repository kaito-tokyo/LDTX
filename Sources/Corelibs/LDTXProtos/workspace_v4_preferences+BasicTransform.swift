// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_BasicTransform {
  public var translationX: Ldtx_Workspace_V4_Rational32? {
    get { hasTranslationXRational ? translationXRational : nil }
    set {
      if let newValue { translationXRational = newValue } else { clearTranslationXRational() }
    }
  }

  public var translationY: Ldtx_Workspace_V4_Rational32? {
    get { hasTranslationYRational ? translationYRational : nil }
    set {
      if let newValue { translationYRational = newValue } else { clearTranslationYRational() }
    }
  }

  public var scaleX: Ldtx_Workspace_V4_Rational32? {
    get { hasScaleXRational ? scaleXRational : nil }
    set {
      if let newValue { scaleXRational = newValue } else { clearScaleXRational() }
    }
  }

  public var scaleY: Ldtx_Workspace_V4_Rational32? {
    get { hasScaleYRational ? scaleYRational : nil }
    set {
      if let newValue { scaleYRational = newValue } else { clearScaleYRational() }
    }
  }

  public var topInset: Ldtx_Workspace_V4_Rational32? {
    get { hasTopInsetRational ? topInsetRational : nil }
    set {
      if let newValue { topInsetRational = newValue } else { clearTopInsetRational() }
    }
  }

  public var rightInset: Ldtx_Workspace_V4_Rational32? {
    get { hasRightInsetRational ? rightInsetRational : nil }
    set {
      if let newValue { rightInsetRational = newValue } else { clearRightInsetRational() }
    }
  }

  public var bottomInset: Ldtx_Workspace_V4_Rational32? {
    get { hasBottomInsetRational ? bottomInsetRational : nil }
    set {
      if let newValue { bottomInsetRational = newValue } else { clearBottomInsetRational() }
    }
  }

  public var leftInset: Ldtx_Workspace_V4_Rational32? {
    get { hasLeftInsetRational ? leftInsetRational : nil }
    set {
      if let newValue { leftInsetRational = newValue } else { clearLeftInsetRational() }
    }
  }

}
