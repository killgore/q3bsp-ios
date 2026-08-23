#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position       [[attribute(0)]];
    float3 normal         [[attribute(1)]];
    float4 color          [[attribute(2)]];
    float2 texCoord       [[attribute(3)]];
    float2 lightmapCoord  [[attribute(4)]];
};

struct VertexOut {
    float4 clipPosition [[position]];
    float4 color;
};

struct PointLight {
    packed_float3 position;
    float range;
    packed_float3 color;
    float attenuation0;
};

struct SceneUniforms {
    float4x4 viewProjectionMatrix;
    packed_float3 ambientColor;
    uint lightCount;
    PointLight lights[2];
};

// Emulates the fixed-function per-vertex (Gouraud) lighting the original
// Direct3D9 renderer relied on: global ambient plus N point lights, each
// contributing a flat in-range/out-of-range term (the original only ever
// sets Attenuation0, so falloff is a step function, not a smooth curve).
vertex VertexOut q3_vertex_main(VertexIn in [[stage_in]],
                                 constant SceneUniforms &scene [[buffer(1)]]) {
    VertexOut out;
    out.clipPosition = scene.viewProjectionMatrix * float4(in.position, 1.0);

    float3 normal = normalize(in.normal);
    float3 lit = scene.ambientColor;

    for (uint i = 0; i < scene.lightCount; i++) {
        PointLight light = scene.lights[i];
        float3 toLight = light.position - in.position;
        float dist = length(toLight);
        if (dist <= light.range) {
            float ndotl = max(dot(normal, toLight / max(dist, 1e-4)), 0.0);
            lit += light.color * ndotl * (1.0 / light.attenuation0);
        }
    }

    out.color = float4(clamp(lit, 0.0, 1.0), 1.0) * in.color;
    out.color.a = in.color.a;
    return out;
}

fragment float4 q3_fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
