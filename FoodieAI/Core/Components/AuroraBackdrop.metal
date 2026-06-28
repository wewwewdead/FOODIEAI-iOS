#include <metal_stdlib>
using namespace metal;

// Interactive aurora backdrop — a fully procedural, GPU-rendered UI background
// (SwiftUI `colorEffect`). A domain-warped fBm flow field is mapped to the brand
// palette and slowly morphs over time; a warm bloom follows the user's touch and
// lifts the flow toward it. One fragment pass over the view — no image, no layers.
//
// Self-contained noise (bd_ prefix) so it doesn't depend on Genie.metal.
static inline float bd_hash(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
static inline float2 bd_grad(float2 i) {
    float a = bd_hash(i) * 6.2831853;
    return float2(cos(a), sin(a));
}
static inline float bd_gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);   // quintic
    float a = dot(bd_grad(i + float2(0.0, 0.0)), f - float2(0.0, 0.0));
    float b = dot(bd_grad(i + float2(1.0, 0.0)), f - float2(1.0, 0.0));
    float c = dot(bd_grad(i + float2(0.0, 1.0)), f - float2(0.0, 1.0));
    float d = dot(bd_grad(i + float2(1.0, 1.0)), f - float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
}
static inline float bd_fbm(float2 p) {
    float v = 0.0, amp = 0.6;
    for (int i = 0; i < 2; i++) {        // 2 octaves — cheap enough for always-on
        v += amp * bd_gnoise(p);
        p = p * 2.0;
        amp *= 0.5;
    }
    return v;
}

[[ stitchable ]]
half4 auroraBackdrop(float2 pos,
                     half4 color,
                     float2 size,
                     float time,
                     float2 touch,
                     float influence) {
    float aspect = size.x / max(size.y, 1.0);
    float2 uv = pos / size;
    float2 puv = float2(uv.x * aspect, uv.y);          // aspect-correct
    float2 p = puv * 2.6;

    // Domain-warped flow field, drifting over time.
    float2 w = float2(bd_fbm(p + float2(0.0, time * 0.06)),
                      bd_fbm(p + float2(5.2, time * 0.05)));
    float n = bd_fbm(p + 1.1 * w + float2(time * 0.04, 0.0));
    float t = clamp(n * 0.5 + 0.5, 0.0, 1.0);

    // Touch bloom: a soft warm light that follows the finger and lifts the flow.
    float2 tuv = float2((touch.x / size.x) * aspect, touch.y / size.y);
    float dist = distance(puv, tuv);
    float glow = influence * exp(-dist * dist * 16.0);
    t = clamp(t + glow * 0.6, 0.0, 1.0);

    // Brand palette: cool accent → lime → cream.
    half3 cool  = half3(0.36, 0.50, 0.56);
    half3 lime  = half3(0.72, 0.79, 0.22);
    half3 cream = half3(0.99, 1.00, 0.97);
    half3 col = mix(cool, lime, half(smoothstep(0.15, 0.60, t)));
    col = mix(col, cream, half(smoothstep(0.60, 0.95, t)));
    col += half3(1.0, 0.93, 0.70) * half(glow) * 0.7;   // warm bloom at the touch

    // Gentle top→bottom depth.
    col *= half(0.85 + 0.15 * (1.0 - uv.y));
    return half4(col, color.a);
}
