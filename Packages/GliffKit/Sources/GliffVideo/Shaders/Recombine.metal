// AVC444 recombine: main + aux NV12 planes -> BGRA, BT.709 limited range. A port of upstream
// Gliff's crates/gliff-vk/shaders/recombine.comp and common.glsl (MIT; see NOTICE).
// One thread per 2x2 block. Without aux (Single420) the main chroma covers the whole block.
// Unlike upstream, no .bgr swizzle: a bgra8Unorm texture already stores B, G, R, A.

#include <metal_stdlib>
using namespace metal;

struct RecombineParams {
    uint width;   // the stream's (display) size, even
    uint height;
    uint hasAux;
};

static float4 toRGB(float y8, float2 c8) {
    float y = y8 * 255.0f - 16.0f;
    float cb = c8.x * 255.0f - 128.0f;
    float cr = c8.y * 255.0f - 128.0f;
    float3 rgb = float3(1.1644f * y + 1.7927f * cr,
                        1.1644f * y - 0.2132f * cb - 0.5329f * cr,
                        1.1644f * y + 2.1124f * cb);
    return float4(clamp(rgb / 255.0f, 0.0f, 1.0f), 1.0f);
}

kernel void recombine(texture2d<float, access::read> mainY [[texture(0)]],
                      texture2d<float, access::read> mainUV [[texture(1)]],
                      texture2d<float, access::read> auxY [[texture(2)]],
                      texture2d<float, access::read> auxUV [[texture(3)]],
                      texture2d<float, access::write> output [[texture(4)]],
                      constant RecombineParams &params [[buffer(0)]],
                      uint2 block [[thread_position_in_grid]]) {
    uint2 p = block * 2;
    if (p.x >= params.width || p.y >= params.height) return;
    float2 c00 = mainUV.read(block).rg;
    float2 c10 = c00, c01 = c00, c11 = c00;
    if (params.hasAux != 0) {
        // Aux Y holds the odd rows' chroma: U in the top half, V in the bottom half.
        uint halfHeight = params.height / 2;
        c10 = auxUV.read(block).rg;
        c01 = float2(auxY.read(uint2(p.x, block.y)).r, auxY.read(uint2(p.x, halfHeight + block.y)).r);
        c11 = float2(auxY.read(uint2(p.x + 1, block.y)).r, auxY.read(uint2(p.x + 1, halfHeight + block.y)).r);
    }
    output.write(toRGB(mainY.read(p).r, c00), p);
    output.write(toRGB(mainY.read(p + uint2(1, 0)).r, c10), p + uint2(1, 0));
    output.write(toRGB(mainY.read(p + uint2(0, 1)).r, c01), p + uint2(0, 1));
    output.write(toRGB(mainY.read(p + uint2(1, 1)).r, c11), p + uint2(1, 1));
}
