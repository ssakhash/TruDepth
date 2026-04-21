#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Self-contained full-screen quad — no vertex buffer required.
vertex VertexOut depth_heatmap_vert(uint vid [[vertex_id]]) {
    const float2 pos[4] = { {-1,-1}, {-1,1}, {1,-1}, {1,1} };
    const float2 uv[4]  = { {0,1},   {0,0},  {1,1},  {1,0} };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    // Rotate landscape camera UVs into portrait screen space (90° CW).
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
                                    constant float& maxDepth [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float d = depthTex.sample(s, in.texCoord).r;
    if (d <= 0.0f || d > maxDepth * 1.5f) discard_fragment();
    return jet(saturate(d / maxDepth));
}
