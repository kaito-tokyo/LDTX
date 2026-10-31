// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <new>

namespace ldtx::audio {

inline constexpr size_t kAudioBufferAlignment = 16;
inline constexpr uint32_t kAudioMaxFramesPerBlock = 65536;

inline size_t alignedSize(size_t size) {
  return (size + kAudioBufferAlignment - 1) & ~(kAudioBufferAlignment - 1);
}

class AlignedStorage {
  void *data_ = nullptr;
  size_t size_ = 0;

public:
  explicit AlignedStorage(size_t size) : size_(alignedSize(size)) {
    if (size_ == 0)
      return;
    if (posix_memalign(&data_, kAudioBufferAlignment, size_) != 0)
      throw std::bad_alloc();
    assert(reinterpret_cast<uintptr_t>(data_) % kAudioBufferAlignment == 0);
  }

  ~AlignedStorage() { free(data_); }

  AlignedStorage(const AlignedStorage &) = delete;
  AlignedStorage &operator=(const AlignedStorage &) = delete;

  std::byte *bytes() { return static_cast<std::byte *>(data_); }
  const std::byte *bytes() const { return static_cast<const std::byte *>(data_); }
  size_t size() const { return size_; }
};

} // namespace ldtx::audio
