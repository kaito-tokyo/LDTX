// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

struct ClockOverlayVertexOutput {
    float4 position [[position]];
};

struct ClockGlyphInstance {
    float4 destinationRect;
    float4 atlasRect;
};

struct ClockOverlayUniforms {
    float4 foregroundColor;
    float4 backgroundColor;
    uint glyphCount;
    uint3 padding;
};

struct ClockOverlayColorAlphaOutput {
    half4 color [[color(0)]];
    half4 alpha [[color(1)]];
};

vertex ClockOverlayVertexOutput clockOverlayVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0f, -1.0f),
        float2(3.0f, -1.0f),
        float2(-1.0f, 3.0f),
    };
    ClockOverlayVertexOutput output;
    output.position = float4(positions[vertexID], 0.0f, 1.0f);
    return output;
}

static inline half clockGlyphCoverage(
    float2 pixel,
    texture2d<half, access::sample> atlas,
    constant ClockOverlayUniforms& uniforms,
    const device ClockGlyphInstance* glyphs
) {
    constexpr sampler atlasSampler(
        coord::normalized,
        address::clamp_to_zero,
        filter::linear
    );
    half coverage = 0.0h;
    for (uint index = 0; index < uniforms.glyphCount; index++) {
        float4 destination = glyphs[index].destinationRect;
        if (pixel.x < destination.x || pixel.y < destination.y ||
            pixel.x >= destination.z || pixel.y >= destination.w) {
            continue;
        }
        float2 size = max(destination.zw - destination.xy, float2(0.0001f));
        float2 local = (pixel - destination.xy) / size;
        float4 atlasRect = glyphs[index].atlasRect;
        float2 atlasUV = mix(atlasRect.xy, atlasRect.zw, local);
        coverage = max(coverage, atlas.sample(atlasSampler, atlasUV).r);
    }
    return coverage;
}

static inline half4 clockOverlayColor(
    float2 pixel,
    texture2d<half, access::sample> atlas,
    constant ClockOverlayUniforms& uniforms,
    const device ClockGlyphInstance* glyphs
) {
    half coverage = clockGlyphCoverage(pixel, atlas, uniforms, glyphs);
    half4 foreground = half4(uniforms.foregroundColor);
    half4 background = half4(uniforms.backgroundColor);
    half foregroundAlpha = clamp(foreground.a * coverage, 0.0h, 1.0h);
    half backgroundAlpha = clamp(background.a, 0.0h, 1.0h);
    half outputAlpha = foregroundAlpha + backgroundAlpha * (1.0h - foregroundAlpha);
    half3 premultiplied =
        foreground.rgb * foregroundAlpha +
        background.rgb * backgroundAlpha * (1.0h - foregroundAlpha);
    half3 straightColor = outputAlpha > 0.0h
        ? premultiplied / outputAlpha
        : half3(0.0h);
    return half4(clamp(straightColor, half3(0.0h), half3(1.0h)), outputAlpha);
}

fragment half4 clockOverlayColorFragment(
    ClockOverlayVertexOutput input [[stage_in]],
    texture2d<half, access::sample> atlas [[texture(0)]],
    constant ClockOverlayUniforms& uniforms [[buffer(0)]],
    const device ClockGlyphInstance* glyphs [[buffer(1)]]
) {
    half4 overlay = clockOverlayColor(input.position.xy, atlas, uniforms, glyphs);
    return half4(overlay.rgb, 1.0h);
}

fragment ClockOverlayColorAlphaOutput clockOverlayColorAlphaFragment(
    ClockOverlayVertexOutput input [[stage_in]],
    texture2d<half, access::sample> atlas [[texture(0)]],
    constant ClockOverlayUniforms& uniforms [[buffer(0)]],
    const device ClockGlyphInstance* glyphs [[buffer(1)]]
) {
    half4 overlay = clockOverlayColor(input.position.xy, atlas, uniforms, glyphs);
    ClockOverlayColorAlphaOutput output;
    output.color = half4(overlay.rgb, 1.0h);
    output.alpha = half4(overlay.a, 0.0h, 0.0h, 1.0h);
    return output;
}
