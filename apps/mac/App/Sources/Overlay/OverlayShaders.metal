#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Silicon Mode overlay shaders. Every function is prefixed `overlay` (the default metallib is
// shared by all modules).

namespace overlay_util {
    inline float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
    inline float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
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
