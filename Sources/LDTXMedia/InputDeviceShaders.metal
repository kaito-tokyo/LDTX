// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

constexpr sampler inputDeviceLinearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

constant uint2 offsetXY [[function_constant(0)]];
constant float2 sourceUV0 [[function_constant(1)]];
constant float2 sourceUVScale0 [[function_constant(2)]];

inline uint videoLumaToFullU8(half luma) {
    half fullRangeLuma = (luma - 16.0h / 255.0h) * (255.0h / 219.0h);
    return uint(clamp(int(fullRangeLuma * 255.0h), 0, 255));
}

inline uint2 videoChromaToFullU8(half2 chroma) {
    half2 fullRangeChroma = 0.5h + (chroma - 128.0h / 255.0h) * (255.0h / 224.0h);
    return uint2(clamp(int2(fullRangeChroma * 255.0h), int2(0), int2(255)));
}

inline uint alphaToU8(half alpha) {
    return uint(clamp(int(alpha * 255.0h + 0.5h), 0, 255));
}

kernel void inputNv12Device0LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0AlphaLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    texture2d<half, access::sample> inputAlpha [[texture(4)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 p = gid + offsetXY;
    uint sourceLuma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    uint destinationLuma = outputLuma.read(p).r;
    uint alpha = alphaToU8(inputAlpha.sample(inputDeviceLinearSampler, inputUV).r);
    uint luma = (sourceLuma * alpha + destinationLuma * (255u - alpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void inputNv12Device0ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0AlphaChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    texture2d<half, access::sample> inputAlpha [[texture(4)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 p = gid + offsetXY;
    uint2 sourceChroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    uint2 destinationChroma = outputChroma.read(p).rg;
    uint alpha = alphaToU8(inputAlpha.sample(inputDeviceLinearSampler, inputUV).r);
    uint2 chroma = (sourceChroma * alpha + destinationChroma * (255u - alpha) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void inputNv12Device0FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = videoLumaToFullU8(inputLuma.sample(inputDeviceLinearSampler, inputUV).r);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = videoChromaToFullU8(inputChroma.sample(inputDeviceLinearSampler, inputUV).rg);
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}
