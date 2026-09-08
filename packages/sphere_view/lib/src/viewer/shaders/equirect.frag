#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uResolution;
uniform float uYaw;
uniform float uPitch;
uniform float uRoll;
uniform float uFov;      // radians, vertical FOV
uniform vec2 uPanoSize;  // in pixels, informational
uniform sampler2D uPano;

out vec4 fragColor;

const float PI = 3.14159265359;

void main() {
    vec2 pos = FlutterFragCoord().xy;
    vec2 uv = (pos / uResolution) * 2.0 - 1.0;
    uv.y = -uv.y;
    float aspect = uResolution.x / uResolution.y;
    float tanHalfFov = tan(uFov * 0.5);
    vec3 dir = normalize(vec3(uv.x * aspect * tanHalfFov, uv.y * tanHalfFov, -1.0));

    // Apply roll around forward axis.
    float cr = cos(uRoll);
    float sr = sin(uRoll);
    dir = vec3(dir.x * cr - dir.y * sr, dir.x * sr + dir.y * cr, dir.z);

    // Pitch around X axis.
    float cp = cos(uPitch);
    float sp = sin(uPitch);
    dir = vec3(dir.x, dir.y * cp - dir.z * sp, dir.y * sp + dir.z * cp);

    // Yaw around Y axis.
    float cy = cos(uYaw);
    float sy = sin(uYaw);
    dir = vec3(dir.x * cy + dir.z * sy, dir.y, -dir.x * sy + dir.z * cy);

    float lon = atan(dir.x, -dir.z);
    float lat = asin(clamp(dir.y, -1.0, 1.0));

    vec2 sampleUv = vec2(
        (lon + PI) / (2.0 * PI),
        0.5 - lat / PI
    );
    fragColor = texture(uPano, sampleUv);
}
