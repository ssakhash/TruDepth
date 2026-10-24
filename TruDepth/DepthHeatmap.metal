#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen quad with no vertex buffer.
vertex VertexOut depth_heatmap_vert(uint vid [[vertex_id]]) {
    const float2 pos[4] = { {-1,-1}, {-1,1}, {1,-1}, {1,1} };
    const float2 uv[4]  = { {0,1},   {0,0},  {1,1},  {1,0} };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    // The SwiftUI 180-degree correction makes the final sensor image 90 degrees clockwise.
    out.texCoord = float2(1.0 - uv[vid].y, uv[vid].x);
    return out;
}

// Jet colormap: 0 = blue (near), 0.5 = green, 1 = red (at maxDepth).
static float4 jet(float t) {
    float r = saturate(1.5f - abs(4.0f * t - 3.0f));
    float g = saturate(1.5f - abs(4.0f * t - 2.0f));
    float b = saturate(1.5f - abs(4.0f * t - 1.0f));
    return float4(r, g, b, 0.82f);
}

fragment float4 depth_heatmap_frag(VertexOut in [[stage_in]],
                                    texture2d<float> depthTex [[texture(0)]],
                                    texture2d<uint, access::read> confidenceTex [[texture(1)]],
                                    constant float& maxDepth [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float d = depthTex.sample(s, in.texCoord).r;
    uint2 pixel = min(uint2(in.texCoord * float2(confidenceTex.get_width(), confidenceTex.get_height())),
                      uint2(confidenceTex.get_width() - 1, confidenceTex.get_height() - 1));
    if (!isfinite(d) || d <= 0.0f || d > maxDepth * 1.5f || confidenceTex.read(pixel).r < 1) discard_fragment();
    return jet(saturate(d / maxDepth));
}
