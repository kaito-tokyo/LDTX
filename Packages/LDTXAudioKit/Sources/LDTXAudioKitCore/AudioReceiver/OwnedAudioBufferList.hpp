// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <type_traits>
#include <vector>

#include <cstdint>

#include <AudioToolbox/AudioToolbox.h>
#include <gsl/pointers>
#include <os/log.h>

#include "logger.hpp"

namespace LDTXAudioKit::AudioReceiverDetail {

struct OwnedAudioBufferList {
  constexpr static std::size_t kAudioBufferAlignment = 16;
  
  OwnedAudioBufferList(std::uint32_t bufferCount, std::uint32_t channelsPerBuffer, std::uint32_t bytesPerBuffer)
  : size_{offsetof(AudioBufferList, mBuffers) + (sizeof(AudioBuffer) * size_t(bufferCount))},
  bytesPerBuffer_{bytesPerBuffer} {
    if (bufferCount == 0) {
      os_log_error(logger(), "bufferCount is zero");
      throw std::invalid_argument("bufferCount is zero");
    }
    if (channelsPerBuffer == 0) {
      os_log_error(logger(), "channelsPerBuffer is zero");
      throw std::invalid_argument("channelsPerBuffer is zero");
    }
    if (bytesPerBuffer == 0) {
      os_log_error(logger(), "bytesPerBuffer is zero");
      throw std::invalid_argument("bytesPerBuffer is zero");
    }
    
    {
      // NOLINTNEXTLINE(cppcoreguidelines-no-malloc)
      gsl::owner<void *> pAbl = std::malloc(size_);
      if (pAbl == nullptr) {
        throw std::bad_alloc();
      }
      std::memset(pAbl, 0, size_);
      abl_ = static_cast<gsl::owner<AudioBufferList *>>(pAbl);
      abl_->mNumberBuffers = bufferCount;
    }
    
    try {
      dataBuffers_.reserve(bufferCount);
      for (std::size_t i = 0; i < bufferCount; i += 1) {
        void *pDataBuffer = nullptr;
        if (posix_memalign(&pDataBuffer, kAudioBufferAlignment, bytesPerBuffer_) != 0) {
          throw std::bad_alloc();
        }
        std::memset(pDataBuffer, 0, bytesPerBuffer_);
        std::unique_ptr<void, void (*)(void *)> dataBuffer{pDataBuffer, &std::free};
        dataBuffers_.emplace_back(std::move(dataBuffer));
        
        // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-constant-array-index)
        auto &buffer = abl_->mBuffers[i];
        buffer.mNumberChannels = channelsPerBuffer;
        buffer.mDataByteSize = bytesPerBuffer;
        buffer.mData = dataBuffers_.rbegin()->get();
      }
    } catch (...) {
      // NOLINTNEXTLINE(cppcoreguidelines-no-malloc)
      std::free(abl_);
      throw;
    }
  }
  
  ~OwnedAudioBufferList() {
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc)
    std::free(abl_);
  }
  
  OwnedAudioBufferList(const OwnedAudioBufferList &) = delete;
  auto operator=(const OwnedAudioBufferList &) -> OwnedAudioBufferList & = delete;
  OwnedAudioBufferList(OwnedAudioBufferList &&) noexcept = delete;
  auto operator=(OwnedAudioBufferList &&) noexcept -> OwnedAudioBufferList & = delete;
  
  [[nodiscard]] auto bytesPerBuffer() const -> std::uint32_t { return bytesPerBuffer_; }
  [[nodiscard]] auto size() const -> std::size_t { return size_; }
  
  [[nodiscard]] auto get() -> AudioBufferList * {
    // NOLINTNEXTLINE(cppcoreguidelines-owning-memory)
    return abl_;
  }
  
  [[nodiscard]] auto get() const -> const AudioBufferList * {
    // NOLINTNEXTLINE(cppcoreguidelines-owning-memory)
    return abl_;
  }
  
private:
  const std::size_t size_;
  gsl::owner<AudioBufferList *> abl_;
  const std::uint32_t bytesPerBuffer_;
  std::vector<std::unique_ptr<void, void (*)(void *)>> dataBuffers_;
  
  static_assert(std::is_standard_layout_v<AudioBufferList>);
};

} // namespace LDTXAudioKit::AudioReceiverDetail
