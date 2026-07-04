// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

struct AudioPeakMeterVertex {
    float4 position;
    float4 color;
};

struct AudioPeakMeterVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex AudioPeakMeterVertexOut audio_peak_meter_vertex(
    const device AudioPeakMeterVertex *vertices [[buffer(0)]],
    uint id [[vertex_id]]
) {
    AudioPeakMeterVertexOut out;
    out.position = vertices[id].position;
    out.color = vertices[id].color;
    return out;
}

fragment float4 audio_peak_meter_fragment(AudioPeakMeterVertexOut in [[stage_in]]) {
    return in.color;
}
