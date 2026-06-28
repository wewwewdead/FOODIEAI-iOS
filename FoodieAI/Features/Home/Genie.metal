#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// --- Procedural fluid physics helpers -------------------------------------
// A 2D CURL field built from a domain-warped, multi-octave GRADIENT-noise
// potential. Curl noise (Bridson 2007) is the curl of a scalar potential, so
// it's divergence-free → advects like an incompressible fluid (swirls, eddies,
// no compression). Upgraded for a smoother, more physically-true look:
//   • gradient (Perlin) noise with QUINTIC interpolation (C2-continuous → no
//     visible derivative seams; "buttery"),
//   • fBm (2 octaves) → eddies at multiple scales like real turbulence. Dropped
//     from 3 octaves: the 3rd was a high-frequency jitter that read as "chatter"
//     more than flow — fewer octaves is both cheaper AND smoother (butterier),
//   • a cheap single-octave domain warp → organic, swirling flow (the full
//     double-fBm warp tripled the per-pixel ALU for a near-invisible gain).
static inline float gn_hash(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
// Pseudo-random unit gradient at a lattice point.
static inline float2 gn_grad(float2 i) {
    float a = gn_hash(i) * 6.2831853;
    return float2(cos(a), sin(a));
}
// Gradient (Perlin) noise, quintic-smoothed, ~[-1, 1].
static inline float gn_gnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);   // quintic
    float a = dot(gn_grad(i + float2(0.0, 0.0)), f - float2(0.0, 0.0));
    float b = dot(gn_grad(i + float2(1.0, 0.0)), f - float2(1.0, 0.0));
    float c = dot(gn_grad(i + float2(0.0, 1.0)), f - float2(0.0, 1.0));
    float d = dot(gn_grad(i + float2(1.0, 1.0)), f - float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
}
// Value-noise-style 0…1 sampler (kept for the stream "snake").
static inline float gn_vnoise(float2 p) {
    return gn_gnoise(p) * 0.5 + 0.5;
}
// 2-octave fBm, scrolling over time so the field evolves. (Was 3 — the top
// octave was high-frequency chatter; 2 reads smoother and costs less.)
static inline float gn_fbm(float2 p, float t) {
    float2 q = p + float2(0.0, t);
    float v = 0.0, amp = 0.60;
    for (int i = 0; i < 2; i++) {
        v += amp * gn_gnoise(q);
        q = q * 2.02 + float2(t * 0.35, 0.0);   // rotate-ish + drift per octave
        amp *= 0.5;
    }
    return v;
}
// Domain-warped scalar flow potential — the source of the swirly, organic flow.
// The warp is sampled with cheap SINGLE-octave gradient noise (not a full fBm):
// at this displacement the organic character is identical, for ~1/3 the ALU.
static inline float gn_potential(float2 p, float t) {
    float2 warp = float2(gn_gnoise(p + float2(0.0, t)),
                         gn_gnoise(p + float2(5.2, 1.3 + t)));
    return gn_fbm(p + 0.9 * warp, t);
}
// Divergence-free velocity = (∂P/∂y, -∂P/∂x), via finite differences.
static inline float2 gn_curl(float2 p, float t) {
    const float e = 0.25;
    float dPdy = (gn_potential(p + float2(0.0, e), t) - gn_potential(p - float2(0.0, e), t)) / (2.0 * e);
    float dPdx = (gn_potential(p + float2(e, 0.0), t) - gn_potential(p - float2(e, 0.0), t)) / (2.0 * e);
    return float2(dPdy, -dPdx);
}

// Genie warp for SwiftUI's `distortionEffect`, modelled on the macOS minimize
// effect. The key to the fluid look is a TRAVELING FRONT: at any instant the
// top rows of the photo are already sucked thin into the target while the
// bottom rows are still full-width at the card, joined by a flowing curved neck
// — not a box that uniformly tapers and slides.
//
// For each DESTINATION pixel `pos` (view point space) we return the SOURCE
// position to sample. The forward map is, per source row v (0 = top, 1 = bottom):
//     pull(v)  = clamp((front - v) / spread, 0, 1)     // top leads
//     destY(v) = mix(cardTop + v*cardH, target.y, smoothstep(pull))
//     width(v) = mix(cardW, targetWidth, pull^1.25)     // necks toward target
//     centerX  = mix(cardCenterX, target.x, pull)
// destY is monotonic in v, so we invert it per-pixel with a short binary search
// to find which row lands on this scanline, then sample across the funnel width.
[[ stitchable ]]
float2 genie(float2 pos,
             float2 cardOrigin,
             float2 cardSize,
             float2 target,
             float targetWidth,
             float g,
             float time) {
    const float OUT = -10000.0;          // sampling here reads transparent
    const float spread = 0.65;           // length of the moving neck (0..1 of body)

    float cardW = cardSize.x;
    float cardH = cardSize.y;
    float cardTop = cardOrigin.y;
    float cardCenterX = cardOrigin.x + cardW * 0.5;
    float front = g * (1.0 + spread);    // sweeps 0 → 1+spread as g: 0 → 1

    // Bounding-box reject (BIG win): this shader runs for EVERY screen pixel, but
    // the funnel only ever lives in the card↔target envelope — at most the card's
    // width, and vertically between the target and the card bottom. Everything
    // outside samples transparent anyway, so skip the per-pixel binary search
    // there entirely. Pure speedup; the visible result is identical.
    const float slop = 40.0;             // snake (≤11) + curl (≤24) wiggle room
    float loX = min(cardCenterX, target.x) - cardW * 0.5 - slop;
    float hiX = max(cardCenterX, target.x) + cardW * 0.5 + slop;
    if (pos.x < loX || pos.x > hiX ||
        pos.y < target.y - 2.0 || pos.y > cardTop + cardH + 2.0) {
        return float2(OUT, OUT);
    }

    // Invert destY(v) = pos.y for the source row v (destY is increasing in v).
    // 11 iterations → ~0.0005 of the card height (sub-pixel) — 14 was overkill;
    // every iteration is paid per screen pixel, so the 3 we save add up.
    float lo = 0.0;
    float hi = 1.0;
    for (int i = 0; i < 11; i++) {
        float mid = 0.5 * (lo + hi);
        float pull = clamp((front - mid) / spread, 0.0, 1.0);
        float e = pull * pull * (3.0 - 2.0 * pull);              // smoothstep
        float dy = mix(cardTop + mid * cardH, target.y, e);
        if (dy < pos.y) { lo = mid; } else { hi = mid; }
    }
    float v = 0.5 * (lo + hi);

    // Outside the funnel's vertical extent → transparent.
    float pull = clamp((front - v) / spread, 0.0, 1.0);
    float e = pull * pull * (3.0 - 2.0 * pull);
    float dyV = mix(cardTop + v * cardH, target.y, e);
    if (abs(dyV - pos.y) > 2.0) {
        return float2(OUT, OUT);
    }

    // Funnel width + center at this row: full at the card, necked at the target.
    float width = mix(cardW, targetWidth, pow(pull, 1.25));
    float centerX = mix(cardCenterX, target.x, pull);

    // --- Physics: the stream has momentum, so it SNAKES side-to-side like a
    //     poured liquid. Travelling wave along the neck, strongest mid-flow. ---
    float energy = sin(pull * 3.14159265) * smoothstep(0.04, 0.32, g) * (1.0 - smoothstep(0.8, 1.0, g));
    float snake = (gn_vnoise(float2(v * 5.0, time * 0.8)) - 0.5) * 2.0;   // -1…1
    centerX += snake * 11.0 * energy;

    float u = (pos.x - centerX) / max(width, 0.5) + 0.5;        // 0…1 across funnel
    if (u < 0.0 || u > 1.0) {
        return float2(OUT, OUT);
    }

    float srcX = cardOrigin.x + u * cardW;
    float srcY = cardTop + v * cardH;

    // --- Physics: divergence-free curl-noise advects the sampled content, so
    //     the photo CHURNS and eddies like real liquid as it's sucked in.
    //     Clamped to the card so the turbulence never samples outside the photo. ---
    if (energy > 0.001) {
        float2 flow = gn_curl(pos * 0.010, time * 0.9);
        srcX += flow.x * 24.0 * energy;
        srcY += flow.y * 24.0 * energy;
        srcX = clamp(srcX, cardOrigin.x, cardOrigin.x + cardW);
        srcY = clamp(srcY, cardOrigin.y, cardOrigin.y + cardH);
    }
    return float2(srcX, srcY);
}

// Outer-glow `layerEffect` for the Dynamic Island pouch: blooms the dish's
// colour around the pouch silhouette (so it reads as glowing edges all around
// the orb) — a single GPU pass that ring-samples the layer's alpha, instead of
// a stack of SwiftUI blurs. `intensity` pulses to make the glow breathe.
[[ stitchable ]]
half4 islandGlow(float2 pos, SwiftUI::Layer layer, half4 glowColor, float radius, float intensity) {
    half4 src = layer.sample(pos);              // premultiplied: pouch = opaque, else clear
    const int N = 16;
    float acc = 0.0;
    for (int i = 0; i < N; i++) {
        float a = (float(i) / float(N)) * 6.2831853;
        float2 dir = float2(cos(a), sin(a));
        acc += layer.sample(pos + dir * radius).a;          // outer ring
        acc += layer.sample(pos + dir * (radius * 0.55)).a; // inner ring (tighter halo)
    }
    acc /= float(N * 2);
    float glow = clamp(acc * intensity, 0.0, 1.0);
    half ga = half(glow) * (1.0h - src.a);     // only OUTSIDE the silhouette
    half3 grgb = glowColor.rgb * ga;           // premultiplied glow colour
    return half4(src.rgb + grgb, src.a + ga);
}
