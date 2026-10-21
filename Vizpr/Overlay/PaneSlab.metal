#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Light for the opaque pane slab. Every term is added to the mesh color, so
// alpha stays whatever the mesh produced (opaque).

constant float kBevelBand = 10.0;     // points inside the edge that the bevel covers
constant float kBevelPeak = 0.2;
constant float kGlowFalloff = 14.0;   // points from the top edge
constant float kGlowPeak = 0.5;
constant float kSheenSlope = 0.6;
constant float kSheenWidth = 0.12;
constant float kSheenPeak = 0.4;
constant float kGrainFps = 24.0;

// Signed distance to a rounded box centered at the origin; negative inside.
static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Lighter toward the top, darker toward the bottom, only near the edge.
static float bevelLight(float2 position, float2 size, float cornerRadius, float strength) {
    float distance = roundedBoxDistance(position - size * 0.5, size * 0.5, cornerRadius);
    float band = 1.0 - smoothstep(0.0, kBevelBand, -distance);
    float side = 1.0 - 2.0 * (position.y / size.y);   // +1 at the top, -1 at the bottom
    return band * side * kBevelPeak * strength;
}

// Soft white light falling off from the top edge, fading out toward the corners.
static float edgeGlowLight(float2 position, float2 size, float strength) {
    float falloff = exp(-position.y / kGlowFalloff);
    float across = position.x / size.x;
    float fade = smoothstep(0.0, 0.2, across) * (1.0 - smoothstep(0.8, 1.0, across));
    return falloff * fade * kGlowPeak * strength;
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

[[ stitchable ]] half4 paneSlab(
    float2 position, half4 color, float2 size, float time,
    float sheenStrength, float sheenSweepSeconds, float edgeGlow,
    float bevel, float grain, float cornerRadius
) {
    float light = bevelLight(position, size, cornerRadius, bevel)
        + edgeGlowLight(position, size, edgeGlow)
        + sheenLight(position, size, time, sheenSweepSeconds, sheenStrength)
        + grainNoise(position, time, grain);
    return half4(color.rgb + half(light) * color.a, color.a);
}
