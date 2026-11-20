// Liquid glass lens: content under a rounded rectangle bends near its rim,
// like looking through the lip of a glass.
//
// Ported from Kyant's Backdrop (AndroidLiquidGlass, `internal/Shaders.kt`,
// REFRACTION) via CYLTabBarController's Android port (`CYLLiquidGlass.kt`).
// Copyright 2025 Kyant. Licensed under the Apache License, Version 2.0.
// Changes: AGSL → Flutter GLSL; used as a backdrop ImageFilter; the shape is
// given in the filter texture's pixel space; one corner radius.

#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// Set by the engine: size of the filter input texture, in pixels.
uniform vec2 uSize;
// The glass shape in texture pixels: left, top, width, height.
uniform vec4 uRect;
uniform float uRadius;
// How far in from the rim the lens reaches, and how far it bends, in pixels.
uniform float uRefractionHeight;
uniform float uRefractionAmount;

uniform sampler2D uTexture;

out vec4 fragColor;

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(cornerCoord, 0.0)) - radius;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
    return sign(coord) * normalize(max(cornerCoord, 0.0));
  }
  float gradX = step(cornerCoord.y, cornerCoord.x);
  return sign(coord) * vec2(gradX, 1.0 - gradX);
}

float circleMap(float x) {
  return 1.0 - sqrt(1.0 - x * x);
}

vec4 sampleAt(vec2 p) {
  vec2 uv = clamp(p, vec2(0.5), uSize - vec2(0.5)) / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 halfSize = uRect.zw * 0.5;
  vec2 centered = frag - uRect.xy - halfSize;
  float radius = min(uRadius, min(halfSize.x, halfSize.y));
  float sd = sdRoundedRect(centered, halfSize, radius);
  if (-sd >= uRefractionHeight || sd > 0.0) {
    fragColor = sampleAt(frag);
    return;
  }
  float d = circleMap(1.0 - -sd / uRefractionHeight) * -uRefractionAmount;
  float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
  vec2 grad = gradSdRoundedRect(centered, halfSize, gradRadius);
  fragColor = sampleAt(frag + d * grad);
}
