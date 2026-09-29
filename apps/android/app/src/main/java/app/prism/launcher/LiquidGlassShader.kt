package app.prism.launcher

/** Screen-space sampling of the actual backdrop. Only the material is shaded, never its text/icons. */
internal const val LIQUID_GLASS_SHADER = """
uniform shader backdrop;
uniform float2 resolution;
uniform float2 viewport;
uniform float2 origin;
uniform float radius;
uniform float density;
uniform float dim;

float roundedDistance(float2 p) {
    float2 q = abs(p - resolution * .5) - resolution * .5 + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

half4 main(float2 p) {
    float d = roundedDistance(p);
    float coverage = 1.0 - smoothstep(-.8, .8, d);
    float bevel = min(18.0 * density, min(resolution.x, resolution.y) * .22);
    float edge = 1.0 - smoothstep(0.0, bevel, -d);
    float2 grad = float2(roundedDistance(p + float2(1, 0)) - roundedDistance(p - float2(1, 0)),
                        roundedDistance(p + float2(0, 1)) - roundedDistance(p - float2(0, 1)));
    grad /= max(length(grad), .001);
    float2 face = (p / resolution - .5) * .12;
    float slope = edge * .91;
    float3 normal = normalize(float3(grad * slope + face, sqrt(max(.08, 1.0 - slope * slope))));
    float3 transmitted = refract(float3(0, 0, -1), normal, 1.0 / 1.46);
    float2 shift = transmitted.xy / max(.25, abs(transmitted.z)) * (22.0 * density);
    float2 screen = origin + p;
    float2 sampleAt = screen + shift;
    // A small channel separation models dispersion at the steep rim.
    half3 color = half3(backdrop.eval(sampleAt + shift * .025).r,
                        backdrop.eval(sampleAt).g,
                        backdrop.eval(sampleAt - shift * .025).b);
    color *= half(1.0 - dim);
    color = mix(color, half3(.035, .05, .07), .16);

    float fresnel = .025 + .65 * pow(1.0 - max(normal.z, 0.0), 5.0);
    float3 reflected = reflect(float3(0, 0, -1), normal);
    half3 environment = backdrop.eval(viewport * .5 + reflected.xy * viewport * .6).rgb;
    color = mix(color, environment, half(fresnel));
    float rim = exp(-abs(d + density * .8) / max(.7, density * .5));
    // A quiet fixed edge defines thickness; the background supplies the optical variation.
    float facingLight = max(dot(normalize(float3(grad, .3)), normalize(float3(-.4, -.6, 1))), 0.0);
    color += half3(.8, .91, 1.0) * half(rim * (.04 + .14 * facingLight));
    return half4(color * half(coverage), half(coverage));
}
"""
