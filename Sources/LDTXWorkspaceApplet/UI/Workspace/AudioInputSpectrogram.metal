// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

struct AudioInputSpectrogramVertexIn {
    float2 position;
    float2 texCoord;
};

struct AudioInputSpectrogramVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct AudioInputSpectrogramFragmentUniforms {
    float4 linePositions;
    float lineWidth;
};

vertex AudioInputSpectrogramVertexOut audio_input_spectrogram_vertex(
    const device AudioInputSpectrogramVertexIn *vertices [[buffer(0)]],
    uint id [[vertex_id]]
) {
    AudioInputSpectrogramVertexOut out;
    out.position = float4(vertices[id].position, 0.0, 1.0);
    out.texCoord = vertices[id].texCoord;
    return out;
}

fragment float4 audio_input_spectrogram_fragment(
    AudioInputSpectrogramVertexOut in [[stage_in]],
    texture2d<float> spectrogramTexture [[texture(0)]],
    sampler spectrogramSampler [[sampler(0)]],
    constant AudioInputSpectrogramFragmentUniforms &uniforms [[buffer(0)]]
) {
    float intensity = spectrogramTexture.sample(spectrogramSampler, in.texCoord).r;
    float y = in.texCoord.y;

    float3 top = float3(0.03, 0.04, 0.06);
    float3 bottom = float3(0.0, 0.0, 0.0);
    float3 background = mix(top, bottom, y);

    float lineContribution = 0.0;
    lineContribution = max(
        lineContribution,
        1.0 - smoothstep(0.0, uniforms.lineWidth, fabs(y - uniforms.linePositions.x))
    );
    lineContribution = max(
        lineContribution,
        1.0 - smoothstep(0.0, uniforms.lineWidth, fabs(y - uniforms.linePositions.y))
    );
    lineContribution = max(
        lineContribution,
        1.0 - smoothstep(0.0, uniforms.lineWidth, fabs(y - uniforms.linePositions.z))
    );
    background += lineContribution * float3(0.08);

    const float4 stopA = float4(0.02, 0.03, 0.08, 0.0);
    const float4 stopB = float4(0.05, 0.18, 0.46, 0.22);
    const float4 stopC = float4(0.05, 0.64, 0.72, 0.45);
    const float4 stopD = float4(0.86, 0.77, 0.19, 0.68);
    const float4 stopE = float4(0.98, 0.35, 0.18, 1.0);

    float3 spectrogramColor = stopE.rgb;
    if (intensity <= stopB.a) {
        float unit = clamp(
            (intensity - stopA.a) / max(stopB.a - stopA.a, 0.0001),
            0.0,
            1.0
        );
        spectrogramColor = mix(stopA.rgb, stopB.rgb, unit);
    } else if (intensity <= stopC.a) {
        float unit = clamp(
            (intensity - stopB.a) / max(stopC.a - stopB.a, 0.0001),
            0.0,
            1.0
        );
        spectrogramColor = mix(stopB.rgb, stopC.rgb, unit);
    } else if (intensity <= stopD.a) {
        float unit = clamp(
            (intensity - stopC.a) / max(stopD.a - stopC.a, 0.0001),
            0.0,
            1.0
        );
        spectrogramColor = mix(stopC.rgb, stopD.rgb, unit);
    } else {
        float unit = clamp(
            (intensity - stopD.a) / max(stopE.a - stopD.a, 0.0001),
            0.0,
            1.0
        );
        spectrogramColor = mix(stopD.rgb, stopE.rgb, unit);
    }

    float alpha = smoothstep(0.0, 0.02, intensity);
    return float4(mix(background, spectrogramColor, alpha), 1.0);
}
