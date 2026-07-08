// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

constant uint2 offsetXY [[function_constant(0)]];
constant float2 sourceUV0 [[function_constant(1)]];
constant float2 sourceUVScale0 [[function_constant(2)]];
constant uint sourceRange [[function_constant(3)]];

inline float sampleUint8(texture2d<uint, access::read> texture, float2 uv, uint channel) {
    float2 size = float2(texture.get_width(), texture.get_height());
    float2 pixel = clamp(uv, float2(0.0f), float2(1.0f)) * size - 0.5f;
    int2 p0 = int2(floor(pixel));
    int2 p1 = p0 + int2(1);
    int2 maxPixel = int2(int(texture.get_width()) - 1, int(texture.get_height()) - 1);
    uint2 c00 = uint2(clamp(p0, int2(0), maxPixel));
    uint2 c10 = uint2(clamp(int2(p1.x, p0.y), int2(0), maxPixel));
    uint2 c01 = uint2(clamp(int2(p0.x, p1.y), int2(0), maxPixel));
    uint2 c11 = uint2(clamp(p1, int2(0), maxPixel));
    float2 f = fract(pixel);
    float v00 = float(texture.read(c00)[channel]);
    float v10 = float(texture.read(c10)[channel]);
    float v01 = float(texture.read(c01)[channel]);
    float v11 = float(texture.read(c11)[channel]);
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

inline uint sampleLuma(texture2d<uint, access::read> luma, float2 uv) {
    return uint(clamp(int(sampleUint8(luma, uv, 0u) + 0.5f), 0, 255));
}

inline uint2 sampleChroma(texture2d<uint, access::read> chroma, float2 uv) {
    return uint2(
        clamp(int(sampleUint8(chroma, uv, 0u) + 0.5f), 0, 255),
        clamp(int(sampleUint8(chroma, uv, 1u) + 0.5f), 0, 255)
    );
}

inline uint sampleAlpha(texture2d<uint, access::read> alpha, float2 uv) {
    return uint(clamp(int(sampleUint8(alpha, uv, 0u) + 0.5f), 0, 255));
}

inline uint sampleRawMaskAlpha(texture2d<half, access::read> mask, float2 uv) {
    float2 size = float2(mask.get_width(), mask.get_height());
    float2 pixel = clamp(uv, float2(0.0f), float2(1.0f)) * size - 0.5f;
    int2 p0 = int2(floor(pixel));
    int2 p1 = p0 + int2(1);
    int2 maxPixel = int2(int(mask.get_width()) - 1, int(mask.get_height()) - 1);
    uint2 c00 = uint2(clamp(p0, int2(0), maxPixel));
    uint2 c10 = uint2(clamp(int2(p1.x, p0.y), int2(0), maxPixel));
    uint2 c01 = uint2(clamp(int2(p0.x, p1.y), int2(0), maxPixel));
    uint2 c11 = uint2(clamp(p1, int2(0), maxPixel));
    float2 f = fract(pixel);
    float v00 = float(mask.read(c00).r);
    float v10 = float(mask.read(c10).r);
    float v01 = float(mask.read(c01).r);
    float v11 = float(mask.read(c11).r);
    float alpha = clamp(mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y), 0.0f, 1.0f);
    return uint(clamp(int(alpha * 255.0f + 0.5f), 0, 255));
}

inline uint sourceLumaToFullU8(uint luma) {
    if (sourceRange == 2u) {
        return luma;
    }
    return uint(clamp((int(luma) - 16) * 255 / 219, 0, 255));
}

inline uint2 sourceChromaToFullU8(uint2 chroma) {
    if (sourceRange == 2u) {
        return chroma;
    }
    return uint2(clamp(int2(128) + (int2(chroma) - int2(128)) * 255 / 224, int2(0), int2(255)));
}

kernel void inputNv12Device0LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0AlphaLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    texture2d<uint, access::read> inputAlpha [[texture(4)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 p = gid + offsetXY;
    uint sourceLuma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    uint destinationLuma = outputLuma.read(p).r;
    uint alpha = sampleAlpha(inputAlpha, inputUV);
    uint luma = (sourceLuma * alpha + destinationLuma * (255u - alpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void inputNv12Device0RawMaskLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    texture2d<half, access::read> inputRawMask [[texture(4)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 p = gid + offsetXY;
    uint sourceLuma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    uint destinationLuma = outputLuma.read(p).r;
    uint alpha = sampleRawMaskAlpha(inputRawMask, inputUV);
    uint luma = (sourceLuma * alpha + destinationLuma * (255u - alpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void inputNv12Device0ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0AlphaChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    texture2d<uint, access::read> inputAlpha [[texture(4)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 p = gid + offsetXY;
    uint2 sourceChroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    uint2 destinationChroma = outputChroma.read(p).rg;
    uint alpha = sampleAlpha(inputAlpha, inputUV);
    uint2 chroma = (sourceChroma * alpha + destinationChroma * (255u - alpha) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void inputNv12Device0RawMaskChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    texture2d<half, access::read> inputRawMask [[texture(4)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 p = gid + offsetXY;
    uint2 sourceChroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    uint2 destinationChroma = outputChroma.read(p).rg;
    uint alpha = sampleRawMaskAlpha(inputRawMask, inputUV);
    uint2 chroma = (sourceChroma * alpha + destinationChroma * (255u - alpha) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void inputNv12Device0FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device0FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device90FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device180FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.x) + 0.5f) / float(gridSize.x),
        (float(gid.y) + 0.5f) / float(gridSize.y)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270LumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270ChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        1.0f - (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHVLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    texture2d<uint, access::read> inputLuma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint luma = sourceLumaToFullU8(sampleLuma(inputLuma, inputUV));
    outputLuma.write(uint4(luma, 0u, 0u, 255u), gid + offsetXY);
}

kernel void inputNv12Device270FlipHVChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    texture2d<uint, access::read> inputChroma [[texture(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    float2 inputUV = sourceUV0 + float2(
        (float(gid.y) + 0.5f) / float(gridSize.y),
        1.0f - (float(gid.x) + 0.5f) / float(gridSize.x)
    ) * sourceUVScale0;
    uint2 chroma = sourceChromaToFullU8(sampleChroma(inputChroma, inputUV));
    outputChroma.write(uint4(chroma, 0u, 255u), gid + offsetXY);
}
