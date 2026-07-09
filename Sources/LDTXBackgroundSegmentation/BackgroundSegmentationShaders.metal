// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

constant uint selfieInputWidth = 256;
constant uint selfieInputHeight = 144;
constant uint selfieInputPlaneCount = selfieInputWidth * selfieInputHeight;
constant uint selfieInputColorRangeVideo = 0;

static inline float clamp01(float value) { return clamp(value, 0.0f, 1.0f); }

static inline float lumaUnit(uint y, bool isVideoRange) {
  if (isVideoRange) {
    return clamp01((float(y) - 16.0f) / 219.0f);
  }
  return float(y) / 255.0f;
}

static inline float3 rgbFromYUV(uint y, uint u, uint v, bool isVideoRange) {
  const float luma = lumaUnit(y, isVideoRange);
  const float chromaScale = isVideoRange ? 224.0f : 255.0f;
  const float cb = (float(u) - 128.0f) / chromaScale;
  const float cr = (float(v) - 128.0f) / chromaScale;
  return clamp(float3(luma + 1.5748f * cr, luma - 0.1873f * cb - 0.4681f * cr, luma + 1.8556f * cb), 0.0f, 1.0f);
}

static inline void fillSelfieInputChannel(texture2d<uint, access::read> lumaTexture,
                                          texture2d<uint, access::read> chromaTexture, device half *input,
                                          uint colorRange, uint channel, uint2 outputCoordinate) {
  if (outputCoordinate.x >= selfieInputWidth || outputCoordinate.y >= selfieInputHeight) {
    return;
  }

  const uint sourceWidth = lumaTexture.get_width();
  const uint sourceHeight = lumaTexture.get_height();
  const uint chromaWidth = chromaTexture.get_width();
  const uint chromaHeight = chromaTexture.get_height();
  const uint sourceX = min(outputCoordinate.x * sourceWidth / selfieInputWidth, sourceWidth - 1);
  const uint sourceY = min(outputCoordinate.y * sourceHeight / selfieInputHeight, sourceHeight - 1);
  const uint chromaX = min(sourceX / 2, chromaWidth - 1);
  const uint chromaY = min(sourceY / 2, chromaHeight - 1);
  const uint y = lumaTexture.read(uint2(sourceX, sourceY)).r;
  const uint2 uv = chromaTexture.read(uint2(chromaX, chromaY)).rg;
  const float3 rgb = rgbFromYUV(y, uv.x, uv.y, colorRange == selfieInputColorRangeVideo);
  const uint inputIndex = outputCoordinate.y * selfieInputWidth + outputCoordinate.x;
  input[channel * selfieInputPlaneCount + inputIndex] = half(rgb[channel]);
}

kernel void fillSelfieInputRedKernel(texture2d<uint, access::read> lumaTexture [[texture(0)]],
                                     texture2d<uint, access::read> chromaTexture [[texture(1)]],
                                     device half *input [[buffer(0)]], constant uint &colorRange [[buffer(1)]],
                                     uint2 outputCoordinate [[thread_position_in_grid]]) {
  fillSelfieInputChannel(lumaTexture, chromaTexture, input, colorRange, 0, outputCoordinate);
}

kernel void fillSelfieInputGreenKernel(texture2d<uint, access::read> lumaTexture [[texture(0)]],
                                       texture2d<uint, access::read> chromaTexture [[texture(1)]],
                                       device half *input [[buffer(0)]], constant uint &colorRange [[buffer(1)]],
                                       uint2 outputCoordinate [[thread_position_in_grid]]) {
  fillSelfieInputChannel(lumaTexture, chromaTexture, input, colorRange, 1, outputCoordinate);
}

kernel void fillSelfieInputBlueKernel(texture2d<uint, access::read> lumaTexture [[texture(0)]],
                                      texture2d<uint, access::read> chromaTexture [[texture(1)]],
                                      device half *input [[buffer(0)]], constant uint &colorRange [[buffer(1)]],
                                      uint2 outputCoordinate [[thread_position_in_grid]]) {
  fillSelfieInputChannel(lumaTexture, chromaTexture, input, colorRange, 2, outputCoordinate);
}

struct BackgroundRemovalSpatialAggregateParameters {
  uint gridWidth;
  uint gridHeight;
  float threshold;
  uint canCompare;
};

struct BackgroundRemovalSpatialSupportParameters {
  uint gridWidth;
  uint gridHeight;
  uint windowWidth;
  uint windowHeight;
  uint requiredChangedCellCount;
};

namespace KaitoTokyo::LDTX::BackgroundRemoval {

static inline uint calculatePartialLumaSum(texture2d<uint, access::read> currentLuma, uint startX, uint startY,
                                           uint cellWidth, uint sampleCount, uint sampleStartIndex, uint sampleStride) {
  uint lumaSum = 0;
  for (uint sampleIndex = sampleStartIndex; sampleIndex < sampleCount; sampleIndex += sampleStride) {
    const uint x = startX + sampleIndex % cellWidth;
    const uint y = startY + sampleIndex / cellWidth;
    lumaSum += currentLuma.read(uint2(x, y)).r;
  }

  return lumaSum;
}

static inline uint calculateChangedCellCount(const device uchar *changedCells, uint gridWidth, uint startX, uint startY,
                                             uint windowWidth, uint windowHeight) {
  uint changedCellCount = 0;
  for (uint offsetY = 0; offsetY < windowHeight; ++offsetY) {
    const uint rowOffset = (startY + offsetY) * gridWidth + startX;
    for (uint offsetX = 0; offsetX < windowWidth; ++offsetX) {
      changedCellCount += uint(changedCells[rowOffset + offsetX]);
    }
  }

  return changedCellCount;
}

} // namespace KaitoTokyo::LDTX::BackgroundRemoval

kernel void backgroundRemovalSpatialAggregateKernel(
    texture2d<uint, access::read> currentLuma [[texture(0)]], device uint *currentAggregates [[buffer(0)]],
    const device uint *referenceAggregates [[buffer(1)]], device uchar *changedCells [[buffer(2)]],
    constant BackgroundRemovalSpatialAggregateParameters &parameters [[buffer(3)]],
    uint threadgroupIndex [[threadgroup_position_in_grid]], uint simdgroupIndex [[simdgroup_index_in_threadgroup]],
    uint simdgroupsPerThreadgroup [[simdgroups_per_threadgroup]], uint laneIndex [[thread_index_in_simdgroup]],
    uint threadsPerSimdgroup [[threads_per_simdgroup]]) {
  using namespace KaitoTokyo::LDTX::BackgroundRemoval;

  const uint cellIndex = threadgroupIndex * simdgroupsPerThreadgroup + simdgroupIndex;
  if (cellIndex >= parameters.gridWidth * parameters.gridHeight) {
    return;
  }

  const uint sourceWidth = currentLuma.get_width();
  const uint sourceHeight = currentLuma.get_height();
  const uint2 cellPosition = uint2(cellIndex % parameters.gridWidth, cellIndex / parameters.gridWidth);
  const uint startX = cellPosition.x * sourceWidth / parameters.gridWidth;
  const uint startY = cellPosition.y * sourceHeight / parameters.gridHeight;
  const uint cellWidth = (cellPosition.x + 1) * sourceWidth / parameters.gridWidth - startX;
  const uint cellHeight = (cellPosition.y + 1) * sourceHeight / parameters.gridHeight - startY;
  const uint sampleCount = cellWidth * cellHeight;
  const uint partialLumaSum =
      calculatePartialLumaSum(currentLuma, startX, startY, cellWidth, sampleCount, laneIndex, threadsPerSimdgroup);
  const uint lumaSum = simd_sum(partialLumaSum);
  if (laneIndex != 0) {
    return;
  }

  currentAggregates[cellIndex] = lumaSum;
  if (parameters.canCompare == 0) {
    changedCells[cellIndex] = 0;
    return;
  }
  const uint referenceSum = referenceAggregates[cellIndex];
  const uint aggregateDifference = max(lumaSum, referenceSum) - min(lumaSum, referenceSum);
  const float thresholdSum = parameters.threshold * float(sampleCount) * 255.0f;
  changedCells[cellIndex] = float(aggregateDifference) >= thresholdSum ? 1 : 0;
}

kernel void backgroundRemovalSpatialSupportKernel(const device uchar *changedCells [[buffer(0)]],
                                                  device atomic_uint *decision [[buffer(1)]],
                                                  constant BackgroundRemovalSpatialSupportParameters &parameters
                                                  [[buffer(2)]],
                                                  uint windowIndex [[thread_position_in_grid]]) {
  using namespace KaitoTokyo::LDTX::BackgroundRemoval;

  const uint windowGridWidth = parameters.gridWidth - parameters.windowWidth + 1;
  const uint windowGridHeight = parameters.gridHeight - parameters.windowHeight + 1;
  const uint windowCount = windowGridWidth * windowGridHeight;
  if (windowIndex >= windowCount) {
    return;
  }

  const uint startX = windowIndex % windowGridWidth;
  const uint startY = windowIndex / windowGridWidth;
  const uint changedCellCount = calculateChangedCellCount(changedCells, parameters.gridWidth, startX, startY,
                                                          parameters.windowWidth, parameters.windowHeight);

  // This threshold count is equivalent to testing the upper median of the window.
  if (changedCellCount >= parameters.requiredChangedCellCount) {
    atomic_store_explicit(decision, 1u, memory_order_relaxed);
  }
}
