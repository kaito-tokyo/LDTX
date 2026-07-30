// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <memory>

/// A non-blocking gate that remains closed while one or more operations hold it.
///
/// Copies share the same counter. The implementation owns all atomic ordering
/// semantics; callers only express the meaningful enter/leave operations.
class LDTXReferenceCountedGate {
public:
  LDTXReferenceCountedGate();
  ~LDTXReferenceCountedGate();

  LDTXReferenceCountedGate(const LDTXReferenceCountedGate &other);
  LDTXReferenceCountedGate &operator=(const LDTXReferenceCountedGate &other);

  void enter() const noexcept;
  void leave() const noexcept;
  bool isClosed() const noexcept;
  uint32_t count() const noexcept;

private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};
