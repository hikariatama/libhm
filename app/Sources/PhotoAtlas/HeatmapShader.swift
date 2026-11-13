enum HeatmapShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Point { float4 coordinate; float4 value; };
    struct Span { uint start; uint count; float originX; float originXLow; };
    struct Uniforms {
        uint2 fieldSize; float2 viewSize;
        float4 projection; // y origin high/low, x/y Mercator-to-field scale
        float4 raster; // halo pixels, field pixels per point, fixed-point scale, kernel radius
    };
    kernel void scatter(device const Point *points [[buffer(0)]],
                        device const Span *spans [[buffer(1)]],
                        device atomic_uint *impulses [[buffer(2)]],
                        constant Uniforms &u [[buffer(3)]],
                        uint group [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]]) {
        Span span = spans[group];
        for (uint i = lane; i < span.count; i += 256) {
            Point p = points[span.start + i];
            float2 d = float2((p.coordinate.x - span.originX) + (p.coordinate.z - span.originXLow),
                             (p.coordinate.y - u.projection.x) + (p.coordinate.w - u.projection.y));
            float2 pixel = d * u.projection.zw + u.raster.x - 0.5;
            if (any(pixel < -1.0) || any(pixel >= float2(u.fieldSize))) continue;
            int2 cell = int2(floor(pixel)); float2 f = fract(pixel);
            for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
                int2 pos = cell + int2(x, y);
                if (any(pos < 0) || any(pos >= int2(u.fieldSize))) continue;
                float weight = (x ? f.x : 1.0 - f.x) * (y ? f.y : 1.0 - f.y);
                uint value = uint(round(p.value.x * weight * u.raster.z));
                atomic_fetch_add_explicit(&impulses[pos.y * u.fieldSize.x + pos.x], value, memory_order_relaxed);
            }
        }
    }
    kernel void horizontal(device const uint *impulses [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                           device const float *weights [[buffer(2)]], texture2d<float, access::write> result [[texture(0)]],
                           uint2 p [[thread_position_in_grid]]) {
        if (any(p >= u.fieldSize)) return;
        int r = int(u.raster.w); float value = 0;
        for (int d = -r; d <= r; ++d) {
            int x = int(p.x) + d;
            if (x >= 0 && x < int(u.fieldSize.x)) value += float(impulses[p.y * u.fieldSize.x + x]) * weights[d + r];
        }
        result.write(value / u.raster.z, p);
    }
    kernel void vertical(texture2d<float, access::read> source [[texture(0)]], texture2d<float, access::write> result [[texture(1)]],
                         constant Uniforms &u [[buffer(0)]], device const float *weights [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
        if (any(p >= u.fieldSize)) return;
        int r = int(u.raster.w); float value = 0;
        for (int d = -r; d <= r; ++d) {
            int y = int(p.y) + d;
            if (y >= 0 && y < int(u.fieldSize.y)) value += source.read(uint2(p.x, y)).r * weights[d + r];
        }
        result.write(value, p);
    }
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex fullscreen(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
    }
    fragment float4 colorize(Vertex v [[stage_in]], texture2d<float> field [[texture(0)]], constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler smooth(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (v.uv * u.viewSize * u.raster.y + u.raster.x) / float2(u.fieldSize);
        float value = max(0.0, field.sample(smooth, uv).r);
        if (value <= 0.003) return float4(0);
        float t = min(1.0, log(1.0 + value) / log(41.0));
        const float stops[] = {0, .24, .42, .61, .80, 1};
        const float3 colors[] = {float3(.60,.30,.88),float3(.65,.38,.92),float3(.36,.83,.85),
                                 float3(1,.89,.46),float3(.98,.54,.76),float3(.98,.54,.76)};
        int i = 0; while (i < 4 && t >= stops[i + 1]) ++i;
        float3 color = mix(colors[i], colors[i + 1], (t - stops[i]) / (stops[i + 1] - stops[i]));
        float alpha = min(.52, value * .85);
        return float4(color * alpha, alpha);
    }
    """#
}
