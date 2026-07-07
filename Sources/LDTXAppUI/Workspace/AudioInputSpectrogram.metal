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
    sampler spectrogramSampler [[sampler(0)]]
) {
    return spectrogramTexture.sample(spectrogramSampler, in.texCoord);
}
