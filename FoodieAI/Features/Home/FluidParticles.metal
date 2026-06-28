#include <metal_stdlib>
using namespace metal;

// GPU particle fluid for the analyzing "liquefy into the island" effect. The
// meal photo is shattered into thousands of colored particles (one per sampled
// pixel) that are advected by physics on the GPU — an attractor that sucks them
// toward the Dynamic Island plus a divergence-free CURL-noise field (Bridson)
// for incompressible, liquid-like swirl — then drawn as soft round sprites that
// overlap into a cohesive fluid surface.
//
// This is a compute + render pipeline driven by `FluidParticleView` (an MTKView):
// `fluidSimulate` steps the particles each frame; `fluidVertex`/`fluidFragment`
// draw them as point sprites.

struct FluidParticle {
    float2 pos;     // view points
    float2 vel;     // points / second
    float4 color;   // straight RGBA sampled from the photo
};

struct FluidUniforms {
    float2 target;        // current attractor (island while gathering, card while returning)
    float2 viewSize;      // drawable size (points)
    float  progress;      // 0 = at card, 1 = gathered at island
    float  time;          // seconds (for the curl field)
    float  dt;            // frame delta (s)
    float  attract;       // attraction acceleration toward target
    float  curlStrength;  // turbulence acceleration
    float  pointSize;     // sprite diameter (px)
    float  phase;         // 0 = gather (→ island), 1 = return (→ card, dissolve)
    float  fade;          // global alpha (1 → 0 over the return so it dissolves)
};

// --- Curl noise (divergence-free → fluid-like) ----------------------------
static inline float fp_hash(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
static inline float fp_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = fp_hash(i);
    float b = fp_hash(i + float2(1.0, 0.0));
    float c = fp_hash(i + float2(0.0, 1.0));
    float d = fp_hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static inline float fp_pot(float2 p, float t) { return fp_vnoise(p + float2(0.0, t)); }
static inline float2 fp_curl(float2 p, float t) {
    const float e = 0.4;
    float dPdy = (fp_pot(p + float2(0.0, e), t) - fp_pot(p - float2(0.0, e), t)) / (2.0 * e);
    float dPdx = (fp_pot(p + float2(e, 0.0), t) - fp_pot(p - float2(e, 0.0), t)) / (2.0 * e);
    return float2(dPdy, -dPdx);
}

// --- Simulation -----------------------------------------------------------
kernel void fluidSimulate(device FluidParticle* ps   [[buffer(0)]],
                          constant FluidUniforms& u   [[buffer(1)]],
                          uint id                     [[thread_position_in_grid]]) {
    FluidParticle p = ps[id];

    float2 toT = u.target - p.pos;
    float dist = max(length(toT), 0.001);
    float2 dir = toT / dist;
    float2 flow = fp_curl(p.pos * 0.012, u.time * 1.5);

    if (u.phase < 0.5) {
        // GATHER: suck toward the island and swirl as a vortex orb.
        float pull = u.attract * (0.15 + 0.85 * u.progress);
        // Each particle holds at its OWN radius (sqrt → uniform disc density) so
        // the cloud fills a swirling orb instead of collapsing to a point.
        float rHash = fract(sin(float(id) * 12.9898) * 43758.5453);
        float holdR = 7.0 + 24.0 * sqrt(rHash);
        float radial = dist - holdR;                        // + outside / - inside
        p.vel += dir * clamp(radial / 60.0, -1.0, 1.0) * pull * u.dt;
        float2 tang = float2(-dir.y, dir.x);                // tangential orbit
        float near = smoothstep(140.0, 25.0, dist);
        p.vel += tang * 150.0 * near * u.dt;
        p.vel += flow * u.curlStrength * u.dt;
        p.vel *= 0.90;
    } else {
        // RETURN: flow back down toward the card and dissolve (fade handled in
        // the vertex shader). Gentle pull to the card target + a little gravity
        // so it pours home, with curl keeping it liquid.
        p.vel += dir * u.attract * 0.55 * u.dt;
        p.vel.y += 700.0 * u.dt;
        p.vel += flow * u.curlStrength * 0.6 * u.dt;
        p.vel *= 0.93;
    }

    p.pos += p.vel * u.dt;
    ps[id] = p;
}

// --- Render (point sprites) ----------------------------------------------
struct FluidVOut {
    float4 position [[position]];
    float  size     [[point_size]];
    float4 color;
};

vertex FluidVOut fluidVertex(uint id                       [[vertex_id]],
                             device const FluidParticle* ps [[buffer(0)]],
                             constant FluidUniforms& u      [[buffer(1)]]) {
    FluidParticle p = ps[id];
    // View points → clip space (-1…1), y flipped.
    float2 ndc = float2(p.pos.x / u.viewSize.x * 2.0 - 1.0,
                        1.0 - p.pos.y / u.viewSize.y * 2.0);
    FluidVOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.size = u.pointSize;
    o.color = float4(p.color.rgb, p.color.a * u.fade);   // global fade → dissolve
    return o;
}

fragment float4 fluidFragment(FluidVOut in        [[stage_in]],
                              float2 pc            [[point_coord]]) {
    float d = length(pc - float2(0.5));
    float a = smoothstep(0.5, 0.12, d) * in.color.a;   // soft round falloff
    // Premultiplied output for standard over-blending → overlapping sprites
    // build a cohesive liquid surface.
    return float4(in.color.rgb * a, a);
}
