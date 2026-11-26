#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Silicon Mode overlay shaders. Every function is prefixed `overlay` (the default metallib is
// shared by all modules).

namespace overlay_util {
    inline float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
    inline float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

    /// Distance from `o` to the farthest corner of a `size` rect.
    inline float farthestCorner(float2 o, float2 size) {
        float a = length(o);
        float b = length(float2(size.x, 0.0) - o);
        float c = length(float2(0.0, size.y) - o);
        float d = length(size - o);
        return max(max(a, b), max(c, d));
    }
}

// MARK: - Enter: NameDrop-style "bump" shockwave reveal
//
// t = seconds since the enter animation started. Timeline:
//   0.00–0.28  glow gathers at the top edge (the notch), nothing of the face is visible yet
//   0.28       bang: flash at the origin, the primary ring leaves
//   0.28–1.15  the ring expands (decelerating, widening), refracting the face like a water lens,
//              with a prismatic rim tinted lavender → peach and a soft light sweep behind it.
//              An echo ring trails 110 ms later. The face is revealed inside the ring.
[[ stitchable ]] half4 overlayBumpShockwave(float2 pos, SwiftUI::Layer layer,
                                            float2 origin, float2 size, float t,
                                            half4 tintA, half4 tintB) {
    const float tBang = 0.28;
    float2 d = pos - origin;
    float dist = length(d);
    float2 dir = dist > 0.001 ? d / dist : float2(0.0, 1.0);
    float maxD = overlay_util::farthestCorner(origin, size);

    // Primary ring
    float ts = max(t - tBang, 0.0);
    float on1 = step(tBang, t);
    float r1 = maxD * 1.14 * (1.0 - exp(-3.1 * ts));
    float w1 = 26.0 + 110.0 * ts;
    float x1 = (dist - r1) / w1;
    float ring1 = exp(-4.0 * x1 * x1) * on1;

    // Echo ring
    float ts2 = max(t - tBang - 0.11, 0.0);
    float on2 = step(tBang + 0.11, t);
    float r2 = maxD * 0.92 * (1.0 - exp(-3.1 * ts2));
    float w2 = 18.0 + 60.0 * ts2;
    float x2 = (dist - r2) / w2;
    float ring2 = exp(-4.0 * x2 * x2) * on2;

    // Lens refraction: derivative-of-gaussian displacement along the radius.
    float2 s = pos;
    s += dir * 58.0 * exp(-1.8 * ts) * (-2.0 * x1) * ring1;
    s += dir * 18.0 * exp(-2.8 * ts2) * (-2.0 * x2) * ring2;
    // The face is slightly pulled toward the origin right behind the rim (liquid drag).
    float behind = smoothstep(0.0, -2.5, x1) * on1 * exp(-2.5 * ts);
    s += dir * 14.0 * behind * exp(-max(r1 - dist, 0.0) / 180.0);

    // Chromatic split on the rim.
    float ca = 9.0 * ring1 * exp(-1.4 * ts) + 3.0 * ring2;
    half4 g = layer.sample(s);
    half4 c = half4(layer.sample(s + dir * ca).r, g.g, layer.sample(s - dir * ca).b, g.a);

    // Reveal inside the ring; guaranteed full reveal once the ring has left the screen.
    float reveal = max(on1 * (1.0 - smoothstep(r1 - w1 * 0.35, r1 + w1 * 0.55, dist)),
                       smoothstep(0.66, 0.88, ts));
    c *= half(reveal);

    // Light
    float gather = smoothstep(0.0, tBang, t) * (1.0 - smoothstep(tBang, tBang + 0.45, t));
    float bloom = gather * gather * exp(-dist / 170.0);
    // A glowing lip along the top edge, brightest at the notch.
    float lip = gather * exp(-abs(d.x) / 340.0) * exp(-max(d.y, 0.0) / 16.0);
    float flash = exp(-dist / 320.0) * exp(-10.0 * ts) * on1;
    float fade = exp(-1.05 * ts);
    float rim = 0.95 * ring1 * fade + 0.32 * ring2 * exp(-2.2 * ts2);
    // White-hot core on the leading edge.
    float core = 0.4 * ring1 * ring1 * fade;
    // Halo spilling outward onto the desktop ahead of the ring.
    float ahead = max(dist - r1, 0.0);
    float halo = on1 * 0.30 * exp(-ahead / (w1 * 1.3)) * smoothstep(r1 - w1 * 0.6, r1, dist) * exp(-1.5 * ts);
    // Soft light sweep trailing inside the ring.
    float sweepX = (dist - (r1 - w1 * 2.2)) / (w1 * 2.4);
    float sweep = 0.17 * on1 * exp(-sweepX * sweepX) * exp(-1.3 * ts);

    float side = clamp(0.5 + 0.5 * dir.x, 0.0, 1.0);
    half4 rimTint = mix(tintA, tintB, half(side));
    half4 white = half4(1.0h);
    c += white * half(saturate(bloom * 1.0 + flash * 0.85 + lip * 0.9 + core));
    c += rimTint * half(saturate(rim + sweep + halo));
    return clamp(c, half4(0.0h), half4(1.0h));
}

// MARK: - Exit: implode back into the notch
//
// p = progress 0…1. The visible disc shrinks toward the origin (ease-in), the content is
// sucked inward behind a refracting rim, and a small glow pops at the notch as it closes.
[[ stitchable ]] half4 overlayImplode(float2 pos, SwiftUI::Layer layer,
                                      float2 origin, float2 size, float p,
                                      half4 tintA, half4 tintB) {
    float2 d = pos - origin;
    float dist = length(d);
    float2 dir = dist > 0.001 ? d / dist : float2(0.0, 1.0);
    float maxD = overlay_util::farthestCorner(origin, size);

    float e = p * p * (1.6 - 0.6 * p);
    float r = maxD * 1.06 * (1.0 - e);
    float w = 22.0 + 60.0 * (1.0 - p);
    float x = (dist - r) / w;
    float ring = exp(-4.0 * x * x);

    // Suction: sample farther out so content appears compressed toward the origin.
    float2 s = pos + dir * (120.0 * e * e) * (dist / max(r, 1.0));
    s += dir * 30.0 * (-2.0 * x) * ring;
    float ca = 4.0 * ring;
    half4 g = layer.sample(s);
    half4 c = half4(layer.sample(s + dir * ca).r, g.g, layer.sample(s - dir * ca).b, g.a);

    float reveal = 1.0 - smoothstep(r - w * 0.4, r + w * 0.5, dist);
    c *= half(reveal);

    float side = clamp(0.5 + 0.5 * dir.x, 0.0, 1.0);
    half4 rimTint = mix(tintA, tintB, half(side));
    float rim = 0.85 * ring * (1.0 - 0.3 * p);
    float core = 0.35 * ring * ring;
    float pop = exp(-dist / 110.0) * smoothstep(0.7, 0.92, p) * (1.0 - smoothstep(0.92, 1.0, p));
    float lip = exp(-abs(d.x) / 240.0) * exp(-max(d.y, 0.0) / 12.0) * smoothstep(0.75, 0.95, p) * (1.0 - smoothstep(0.95, 1.0, p));
    c += rimTint * half(saturate(rim));
    c += half4(1.0h) * half(saturate(pop * 0.9 + lip * 0.6 + core));
    return clamp(c, half4(0.0h), half4(1.0h));
}

// MARK: - Panic: glitch
//
// RGB split, horizontal tearing, jitter and static scanlines. The tearing steps at ~9 Hz but
// only *moves* content in thin bands; it does not flash the screen's overall luminance (the
// only luminance flicker is sparse small blocks, well under the WCAG 2.3.1 area threshold).
[[ stitchable ]] half4 overlayPanicGlitch(float2 pos, SwiftUI::Layer layer,
                                          float2 size, float t, float amount) {
    float tick = floor(t * 9.0);
    // Bursty: ~40% of ticks tear hard, the rest only shimmer, so the message stays readable.
    float burst = step(0.6, overlay_util::hash11(tick * 0.91 + 0.3));
    float amt = amount * mix(0.22, 1.0, burst);
    float bandH = mix(6.0, 70.0, overlay_util::hash11(tick * 1.37 + 0.5));
    float band = floor(pos.y / bandH);
    float tear = overlay_util::hash21(float2(band, tick));
    float tearOn = step(mix(0.95, 0.76, burst), tear);

    float2 s = pos;
    s.x += (overlay_util::hash21(float2(band + 11.0, tick + 7.0)) - 0.5) * 150.0 * tearOn * amt;
    s.x += (overlay_util::hash11(floor(t * 24.0)) - 0.5) * 6.0 * amt;

    float split = (2.5 + 14.0 * overlay_util::hash11(tick + 3.0)) * amt;
    half4 g = layer.sample(s);
    half4 rs = layer.sample(s + float2(split, 0.0));
    half4 bs = layer.sample(s - float2(split, 0.0));
    half a = max(g.a, max(rs.a, bs.a));
    half4 c = half4(rs.r, g.g, bs.b, a);

    // Static scanlines (no flicker).
    float scan = 0.84 + 0.16 * sin(pos.y * 3.14159 / 1.5);
    c.rgb *= half(scan);

    // Sparse small corrupted blocks.
    float2 blk = floor(pos / float2(56.0, 14.0));
    float n = overlay_util::hash21(blk + float2(tick * 0.73, tick * 1.91));
    if (n > 0.997 - 0.006 * burst * amount) {
        c = mix(c, half4(1.0h, 0.16h, 0.2h, 1.0h), half(0.75 * amount));
    }
    return c;
}
