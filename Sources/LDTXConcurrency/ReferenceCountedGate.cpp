// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "LDTXConcurrency/ReferenceCountedGate.hpp"

#include <atomic>
#include <cstdlib>
#include <limits>

struct LDTXReferenceCountedGate::Impl {
  std::atomic<uint32_t> count{0};
};

LDTXReferenceCountedGate::LDTXReferenceCountedGate() : impl_(std::make_shared<Impl>()) {}

LDTXReferenceCountedGate::~LDTXReferenceCountedGate() = default;

LDTXReferenceCountedGate::LDTXReferenceCountedGate(const LDTXReferenceCountedGate &other) = default;

LDTXReferenceCountedGate &LDTXReferenceCountedGate::operator=(const LDTXReferenceCountedGate &other) = default;

void LDTXReferenceCountedGate::enter() const noexcept {
  auto current = impl_->count.load(std::memory_order_seq_cst);
  while (current != std::numeric_limits<uint32_t>::max()) {
    if (impl_->count.compare_exchange_weak(current, current + 1, std::memory_order_seq_cst,
                                           std::memory_order_seq_cst)) {
      return;
    }
  }
  std::abort();
}

void LDTXReferenceCountedGate::leave() const noexcept {
  auto current = impl_->count.load(std::memory_order_seq_cst);
  while (current > 0) {
    if (impl_->count.compare_exchange_weak(current, current - 1, std::memory_order_seq_cst,
                                           std::memory_order_seq_cst)) {
      return;
    }
  }
  std::abort();
}

bool LDTXReferenceCountedGate::isClosed() const noexcept { return impl_->count.load(std::memory_order_seq_cst) > 0; }

uint32_t LDTXReferenceCountedGate::count() const noexcept { return impl_->count.load(std::memory_order_seq_cst); }
