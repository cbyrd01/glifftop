#include <metal_stdlib>
using namespace metal;

// Draws a picture as one quad over the viewport the renderer sets (VideoFit.viewport).

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

// Four vertices as a triangle strip: (0,0) (1,0) (0,1) (1,1), top-left first. `uvScale` is
// the picture's share of its texture.
vertex QuadOut picture_vertex(uint vid [[vertex_id]], constant float2 &uvScale [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    QuadOut out;
    out.position = float4(corner.x * 2 - 1, 1 - corner.y * 2, 0, 1);
    out.uv = corner * uvScale;
    return out;
}

fragment half4 picture_fragment(QuadOut in [[stage_in]], texture2d<half> picture [[texture(0)]],
                                sampler pictureSampler [[sampler(0)]]) {
    return picture.sample(pictureSampler, in.uv);
}
