import Foundation

/// Shader source, compiled at runtime by the Metal framework.
///
/// Kept as a string rather than a .metal file on purpose: offline shader
/// compilation needs Xcode's separately-downloaded Metal Toolchain, and
/// runtime compilation costs a few milliseconds at launch while keeping the
/// package buildable on any Mac with Xcode installed.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float    xmin;
    float    ymin;
    float    res;
    uint     nx;
    uint     ny;
    float    top;
    float    bottom;
    float    shade;      // 1 = shaded, 0 = flat (wireframe)
};

struct VOut {
    float4 position [[position]];
    float3 color;
};

static float sampleH(texture2d<float> heights, uint ix, uint iy, uint nx, uint ny) {
    ix = min(ix, nx - 1);
    iy = min(iy, ny - 1);
    return heights.read(uint2(ix, iy)).r;
}

// The height grid is the geometry: one vertex per cell, displaced in Z by
// the texture. No mesh is ever built on the CPU.
vertex VOut surfaceVertex(uint vid [[vertex_id]],
                          constant Uniforms &u [[buffer(0)]],
                          texture2d<float> heights [[texture(0)]])
{
    // Triangles are derived from the vertex id rather than an index buffer.
    // At a 0.12mm grid the indices alone would be ~286MB; this way there is
    // no buffer at all.
    uint quad = vid / 6u;
    uint corner = vid % 6u;
    uint qx = quad % (u.nx - 1u);
    uint qy = quad / (u.nx - 1u);

    const uint2 offs[6] = { uint2(0,0), uint2(1,0), uint2(1,1),
                            uint2(0,0), uint2(1,1), uint2(0,1) };
    uint ix = qx + offs[corner].x;
    uint iy = qy + offs[corner].y;
    float z = sampleH(heights, ix, iy, u.nx, u.ny);

    float3 p = float3(u.xmin + float(ix) * u.res,
                      u.ymin + float(iy) * u.res,
                      z);

    // Normal from neighbouring cells, so cut walls catch the light.
    float zl = sampleH(heights, ix == 0 ? 0 : ix - 1, iy, u.nx, u.ny);
    float zr = sampleH(heights, ix + 1, iy, u.nx, u.ny);
    float zd = sampleH(heights, ix, iy == 0 ? 0 : iy - 1, u.nx, u.ny);
    float zu = sampleH(heights, ix, iy + 1, u.nx, u.ny);
    float3 n = normalize(float3(zl - zr, zd - zu, 2.0 * u.res));

    float depth = max(u.top - u.bottom, 1e-6);
    float t = clamp((z - u.bottom) / depth, 0.0, 1.0);
    float3 base = mix(float3(0.16, 0.16, 0.20), float3(0.88, 0.80, 0.68), t);

    float lambert = max(dot(n, normalize(float3(0.35, 0.35, 0.87))), 0.0);
    float lit = 0.35 + 0.65 * lambert;

    VOut o;
    o.position = u.mvp * float4(p, 1.0);
    o.color = mix(base, base * lit, u.shade);
    return o;
}

fragment float4 surfaceFragment(VOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

// Flat quad closing the bottom of the block, so cut-through reads as a
// hole rather than a gap.
vertex VOut baseVertex(uint vid [[vertex_id]],
                       constant Uniforms &u [[buffer(0)]])
{
    float w = float(u.nx - 1) * u.res;
    float d = float(u.ny - 1) * u.res;
    float2 corner[6] = {
        float2(0, 0), float2(w, 0), float2(w, d),
        float2(0, 0), float2(w, d), float2(0, d)
    };
    float2 c = corner[vid];
    VOut o;
    o.position = u.mvp * float4(u.xmin + c.x, u.ymin + c.y, u.bottom, 1.0);
    o.color = float3(0.10, 0.10, 0.13);
    return o;
}

// ---------------------------------------------------------------- toolpath

struct PathVertex {
    packed_float3 p;
    uint category;     // 0 travel above, 1 travel at depth, 2 cut, 3 arc, 4 plunge
    uint moveIndex;
    uint section;
};

struct PathUniforms {
    float4x4 mvp;
    uint  maxMove;      // hide anything the tool has not reached yet
    uint  mask;         // one bit per category
    uint  colorMode;    // 0 by category, 1 by section
    uint  sectionCount;
    float pointSize;
};

struct PVOut {
    float4 position [[position]];
    float3 color;
    float  size [[point_size]];
};

static float3 hue(float h) {
    float3 k = fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
    return clamp(abs(k) - 1.0, 0.0, 1.0);
}

vertex PVOut pathVertex(uint vid [[vertex_id]],
                        const device PathVertex *verts [[buffer(0)]],
                        constant PathUniforms &u [[buffer(1)]])
{
    PathVertex v = verts[vid];
    PVOut o;
    o.size = u.pointSize;

    bool hidden = (v.moveIndex > u.maxMove) || ((u.mask & (1u << v.category)) == 0u);
    if (hidden) {
        // Behind the near plane, so it is clipped rather than drawn.
        o.position = float4(0.0, 0.0, -1.0, 1.0);
        o.color = float3(0.0);
        return o;
    }

    float3 c;
    if (u.colorMode == 1u && v.category != 0u && v.category != 1u) {
        c = mix(float3(0.35), hue(fract(float(v.section) * 0.61803399)), 0.85);
    } else {
        switch (v.category) {
            case 0u: c = float3(0.35, 0.48, 0.70); break;   // travel, clear of stock
            case 1u: c = float3(1.00, 0.25, 0.20); break;   // travel at depth
            case 2u: c = float3(0.55, 0.95, 0.60); break;   // cutting
            case 3u: c = float3(0.35, 0.85, 0.90); break;   // cutting, arc
            default: c = float3(1.00, 0.70, 0.15); break;   // plunge
        }
    }

    o.position = u.mvp * float4(float3(v.p), 1.0);
    o.color = c;
    return o;
}

fragment float4 pathFragment(PVOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
"""#
