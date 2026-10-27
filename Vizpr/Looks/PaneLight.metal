#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Light drawn over any pane surface, as premultiplied color: light is
// (a, a, a, a), darkening is (0, 0, 0, a). Composited over the surface, it
// leaves the surface's own alpha alone where the layer is clear.

constant float kBevelBand = 10.0;     // points inside the edge that the bevel covers
constant float kBevelPeak = 0.2;
constant float kEdgeFalloff = 14.0;   // points from the top edge
constant float kEdgePeak = 0.5;
constant float kGlossPeak = 0.35;
constant float kSheenSlope = 0.6;
constant float kSheenWidth = 0.12;
constant float kSheenPeak = 0.4;
constant float kGrainFps = 24.0;

// Signed distance to a rounded box centered at the origin; negative inside.
static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Signed light: positive lightens, negative darkens. Lighter toward the top,
// darker toward the bottom, only near the edge.
static float bevelLight(float2 position, float2 size, float cornerRadius, float strength) {
    float distance = roundedBoxDistance(position - size * 0.5, size * 0.5, cornerRadius);
    float band = 1.0 - smoothstep(0.0, kBevelBand, -distance);
    float side = 1.0 - 2.0 * (position.y / size.y);   // +1 at the top, -1 at the bottom
    return band * side * kBevelPeak * strength;
}

// Soft white light falling off from the top edge, fading out toward the corners.
static float edgeLight(float2 position, float2 size, float strength) {
    float falloff = exp(-position.y / kEdgeFalloff);
    float across = position.x / size.x;
    float fade = smoothstep(0.0, 0.2, across) * (1.0 - smoothstep(0.8, 1.0, across));
    return falloff * fade * kEdgePeak * strength;
}

// A still, soft elliptical highlight across the top third: about 70% of the
// width wide, gaussian falloff.
static float glossLight(float2 position, float2 size, float strength) {
    float2 center = float2(size.x * 0.5, size.y * 0.12);
    float2 radii = float2(size.x * 0.35, max(size.y * 0.24, 8.0));
    float2 d = (position - center) / radii;
    return exp(-dot(d, d) * 1.5) * kGlossPeak * strength;
}

// A diagonal band that sweeps across and then rests offscreen for the rest of the cycle.
static float sheenLight(float2 position, float2 size, float time, float sweepSeconds, float strength) {
    float u = (position.x + kSheenSlope * position.y) / (size.x + kSheenSlope * size.y);
    float phase = fract(time / sweepSeconds);
    float center = mix(-0.3, 1.3, phase);
    float offset = (u - center) / kSheenWidth;
    return exp(-offset * offset) * kSheenPeak * strength;
}

// Zero-centered hash noise, re-rolled kGrainFps times a second.
static float grainNoise(float2 position, float time, float amount) {
    float2 cell = floor(position) + floor(time * kGrainFps);
    float hash = fract(sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453);
    return (hash - 0.5) * amount;
}

[[ stitchable ]] half4 paneLight(
    float2 position, half4 color, float2 size, float time, float cornerRadius,
    float edge, float bevel, float gloss, float sheen, float sheenSweepSeconds, float grain
) {
    float light = bevelLight(position, size, cornerRadius, bevel)
        + edgeLight(position, size, edge)
        + glossLight(position, size, gloss)
        + sheenLight(position, size, time, sheenSweepSeconds, sheen)
        + grainNoise(position, time, grain);
    float alpha = min(abs(light), 1.0);
    return light >= 0 ? half4(half3(alpha), half(alpha)) : half4(0, 0, 0, half(alpha));
}
