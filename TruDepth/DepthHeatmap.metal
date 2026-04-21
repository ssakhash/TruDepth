#include <metal_stdlib>
using namespace metal;

// Full-screen quad vertex shader — no vertex buffer needed.
vertex float4 depth_heatmap_vert(uint vid [[vertex_id]],
                                  constant float4* verts [[buffer(0)]]) {
    return verts[vid];
}

// Maps a normalised depth value [0,1] through a jet colormap:
//   0 = blue (near), 0.5 = green, 1 = red (far / at maxDepth)
static float4 jet(float t) {
    float r = saturate(1.5f - abs(4.0f * t - 3.0f));
    float g = saturate(1.5f - abs(4.0f * t - 2.0f));
    float b = saturate(1.5f - abs(4.0f * t - 1.0f));
    return float4(r, g, b, 0.82f);
}

fragment float4 depth_heatmap_frag(float4 pos [[position]],
                                    texture2d<float> depthTex [[texture(0)]],
                                    constant float& maxDepth [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // pos is in pixel coordinates; convert to [0,1] UV
    float2 uv = float2(pos.x / depthTex.get_width(), pos.y / depthTex.get_height());
    float d = depthTex.sample(s, uv).r;

    // Discard pixels with no depth data or beyond 1.5× the configured range
    if (d <= 0.0f || d > maxDepth * 1.5f) discard_fragment();

    return jet(saturate(d / maxDepth));
}
