import Foundation

/// Metal shader source, compiled at launch. Uniform names are generated from
/// `Slot`, so the Swift side and the shader side cannot drift apart.
enum Shaders {
    static var source: String {
        var defines = ""
        for s in Slot.allCases { defines += "#define u_\(s) U.f[\(s.rawValue)]\n" }
        return header + defines + body
    }

    private static let header = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float f[\(slotCount)]; };

    """

    private static let body = """

    constexpr sampler sMirror(filter::linear, address::mirrored_repeat);
    constexpr sampler sClamp(filter::linear, address::clamp_to_edge);

    struct VSOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex VSOut vs_full(uint vid [[vertex_id]]) {
        VSOut o;
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // ---------------------------------------------------------------- helpers

    static inline float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }

    static inline float2 rot2(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y);
    }

    static inline float3 pal(float t, constant Uniforms &U) {
        float3 a = float3(u_palA0, u_palA1, u_palA2);
        float3 b = float3(u_palB0, u_palB1, u_palB2);
        float3 c = float3(u_palC0, u_palC1, u_palC2);
        float3 d = float3(u_palD0, u_palD1, u_palD2);
        return max(a + b * cos(6.2831853 * (c * t + d)), 0.0);
    }

    // Fold the plane into one mirrored wedge: the kaleidoscope.
    static inline float2 kfold(float2 p, float n, float rot) {
        float a = atan2(p.y, p.x) + rot;
        float seg = 6.2831853 / n;
        a = a - seg * floor(a / seg);
        a = abs(a - seg * 0.5);
        return float2(cos(a), sin(a)) * length(p);
    }

    static inline float specAt(texture2d<float> t, float x) { return t.sample(sClamp, float2(x, 0.125)).r; }
    static inline float waveAt(texture2d<float> t, float x) { return t.sample(sClamp, float2(x, 0.375)).r * 2.0 - 1.0; }
    static inline float peakAt(texture2d<float> t, float x) { return t.sample(sClamp, float2(x, 0.625)).r; }

    // Equaliser bars. Returns (body, cap, bar position 0..1, height 0..1).
    static float4 barsAt(float2 p, float aspect, texture2d<float> audioTex, constant Uniforms &U) {
        float mode = u_barsMode;
        float t, y, H;
        if (mode < 0.5) {            // rising from the bottom edge
            t = p.x / (2.0 * aspect * 0.94) + 0.5;
            y = p.y + 0.94;
            H = 1.3;
        } else if (mode < 1.5) {     // mirrored around the centre line
            t = p.x / (2.0 * aspect * 0.94) + 0.5;
            y = abs(p.y);
            H = 0.8;
        } else {                     // radial
            float a = atan2(p.y, p.x) / 6.2831853 + 0.25;
            t = abs(fract(a) * 2.0 - 1.0);
            y = length(p) - (0.28 + 0.06 * u_bass);
            H = 0.6;
        }
        if (t < 0.0 || t > 1.0 || y < 0.0) return float4(0.0);

        float N = max(u_barsCount, 4.0);
        float fx = t * N;
        float idx = floor(fx);
        float fr = fx - idx;
        float bt = (idx + 0.5) / N;
        float v = specAt(audioTex, bt);
        float pk = peakAt(audioTex, bt);
        float aa = clamp(N * 2.5 / u_resX, 0.01, 0.2);
        float gap = smoothstep(0.10, 0.10 + aa, fr) * (1.0 - smoothstep(0.90 - aa, 0.90, fr));
        float h = y / H;
        float body = (1.0 - smoothstep(v - 0.003, v + 0.003, h)) * gap * step(0.006, v);
        float seg = u_barsSeg;
        if (seg > 1.0) {
            float sf = fract(h * seg);
            body *= smoothstep(0.0, 0.14, sf) * (1.0 - smoothstep(0.74, 0.88, sf));
        }
        float cap = gap * (1.0 - smoothstep(0.004, 0.008, abs(h - pk - 0.014))) * step(0.01, pk);
        return float4(body, cap, bt, h);
    }

    static inline float3 barsColor(float4 b, constant Uniforms &U) {
        float3 c = pal(u_palPhase + 0.15 + b.z * u_palSpread * 0.6 + b.w * 0.25, U);
        return c * (0.55 + 0.75 * b.w) * b.x + mix(c, float3(1.0), 0.65) * b.y;
    }

    // ---------------------------------------------------------------- feedback pass
    // Reads the previous frame through a warp, fades it, and paints this
    // frame's audio-driven "ink" on top. Everything interesting happens here.

    fragment float4 fs_feedback(VSOut in [[stage_in]],
                                texture2d<float> prevTex [[texture(0)]],
                                texture2d<float> audioTex [[texture(1)]],
                                constant Uniforms &U [[buffer(0)]])
    {
        float aspect = u_aspect;
        float2 p = float2((in.uv.x - 0.5) * 2.0 * aspect, (0.5 - in.uv.y) * 2.0);
        if (u_mirror > 0.5) p.x = abs(p.x);
        float kN = u_kaleidoN;
        if (kN >= 2.0) p = kfold(p, kN, u_kaleidoRot);

        float r = length(p);
        float ang = atan2(p.y, p.x);
        float k = u_dt60 * u_warpGlobal;

        // ---- where did this pixel come from last frame?
        float2 q = p;
        float z = (u_zoom + u_zoomBass * u_bass) * (1.0 + u_zoomCurve * (r - 0.6));
        q *= 1.0 - z * 0.018 * k;
        float ra = (u_rot + u_rotBass * (u_bass - 0.3)) * 0.018 * k
                 + u_swirl * 0.03 * k * sin(r * u_swirlFreq - u_time * 0.7);
        q = rot2(q, ra);
        float wt = u_time * u_warpSpeed;
        q += u_warpAmp * 0.010 * k * float2(
            sin(p.y * u_warpFreq + wt) + 0.5 * sin(p.y * u_warpFreq * 2.3 - wt * 1.7),
            cos(p.x * u_warpFreq * 1.13 - wt * 0.83) + 0.5 * cos(p.x * u_warpFreq * 2.1 + wt * 1.3));
        q += (p / max(r, 1e-4)) * sin(r * u_rippleFreq - u_time * 3.0) * u_ripple * 0.006 * k * (0.4 + u_bass);
        q += float2(u_driftX, u_driftY) * 0.004 * k;

        float2 uvp = float2(q.x / aspect * 0.5 + 0.5, 0.5 - q.y * 0.5);
        float3 col = prevTex.sample(sMirror, uvp).rgb;
        if (u_blur > 0.001) {
            float2 px = 1.5 / float2(u_resX, u_resY);
            float3 avg = prevTex.sample(sMirror, uvp + float2(px.x, 0.0)).rgb
                       + prevTex.sample(sMirror, uvp - float2(px.x, 0.0)).rgb
                       + prevTex.sample(sMirror, uvp + float2(0.0, px.y)).rgb
                       + prevTex.sample(sMirror, uvp - float2(0.0, px.y)).rgb;
            col = mix(col, avg * 0.25, u_blur);
        }

        // ---- fade and slowly rotate the hue of the trails
        col *= pow(u_decay, u_dt60);
        col = max(col - 0.0012 * u_dt60, 0.0);
        // Large bright areas burn out faster, which keeps the picture from filling in.
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col *= 1.0 - 0.05 * smoothstep(0.45, 1.2, lum) * u_dt60;
        float hs = u_hueShift * 0.012 * u_dt60;
        if (abs(hs) > 1e-5) {
            float ch = cos(hs), sh = sin(hs);
            float3 ax = float3(0.57735);
            col = max(col * ch + cross(ax, col) * sh + ax * dot(ax, col) * (1.0 - ch), 0.0);
        }

        // ---- new ink
        float3 ink = float3(0.0);
        float phase = u_palPhase;
        float spread = u_palSpread;

        // Waveform
        if (u_waveAmt > 0.001) {
            float w = 0.004 + 0.006 * u_waveThick;
            float tx = p.x / (2.0 * aspect) + 0.5;
            float d;
            float ct;
            if (u_waveMode < 0.5) {                 // oscilloscope line
                float y0 = waveAt(audioTex, tx) * u_waveAmp * 0.45;
                float y1 = waveAt(audioTex, tx + 0.003) * u_waveAmp * 0.45;
                float slope = (y1 - y0) / (0.003 * 2.0 * aspect);
                d = abs(p.y - y0) / sqrt(1.0 + slope * slope);
                ct = tx;
            } else if (u_waveMode < 1.5) {          // circle
                float ta = abs(fract(ang / 6.2831853 + 0.25 + u_time * 0.02) * 2.0 - 1.0);
                float R = u_waveRadius * (1.0 + 0.25 * u_bass) + waveAt(audioTex, ta) * u_waveAmp * 0.22;
                d = abs(r - R);
                ct = ta;
            } else if (u_waveMode < 2.5) {          // twin mirrored lines
                float y0 = 0.5 + waveAt(audioTex, tx) * u_waveAmp * 0.28;
                d = abs(abs(p.y) - y0);
                ct = tx;
            } else {                                // spectrum ring
                float ta = abs(fract(ang / 6.2831853 + 0.25) * 2.0 - 1.0);
                float R = u_waveRadius * 0.8 + specAt(audioTex, ta) * u_waveAmp * 0.5;
                d = abs(r - R);
                ct = ta;
            }
            float I = exp(-(d * d) / (w * w));
            ink += pal(phase + ct * spread, U) * I * u_waveAmt * (0.75 + 0.6 * u_level);
        }

        // Equaliser bars bleeding into the trails
        if (u_barsInk > 0.001) {
            float4 b = barsAt(p, aspect, audioTex, U);
            ink += barsColor(b, U) * u_barsInk * 0.55;
        }

        // Orbs on Lissajous paths, each listening to a different band
        if (u_orbAmt > 0.001) {
            for (int i = 0; i < 8; i++) {
                float fi = float(i);
                if (fi >= u_orbCount) break;
                float h1 = hash11(fi * 1.7 + u_seed);
                float h2 = hash11(fi * 3.1 + u_seed + 5.0);
                float tt = u_time * u_orbSpeed * (0.4 + h1) * 0.6 + u_bassAccum * 0.5 * h2 + h2 * 6.2831853;
                float2 c = float2(cos(tt * (1.0 + h2)), sin(tt * 1.3 + h1 * 6.2831853)) * u_orbSpread * (0.3 + 0.7 * h1);
                c.x *= min(aspect, 1.5);
                if (u_mirror > 0.5) c.x = abs(c.x);
                if (kN >= 2.0) c = kfold(c, kN, u_kaleidoRot);
                int m = i % 3;
                float band = m == 0 ? u_bass : (m == 1 ? u_mid : u_treble);
                float rad = u_orbSize * 0.035 * (0.45 + 1.4 * band);
                float2 dv = p - c;
                float I = exp(-dot(dv, dv) / (rad * rad));
                ink += pal(phase + h1 * spread + 0.1, U) * I * u_orbAmt * 1.1;
            }
        }

        // Plasma contour lines
        if (u_plasmaAmt > 0.001) {
            float2 s = p * u_plasmaScale;
            float tt = u_time * u_plasmaSpeed;
            float v = sin(s.x * 1.3 + tt) + sin(s.y * 1.7 - tt * 0.8)
                    + sin((s.x + s.y) * 0.9 + tt * 0.6) + sin(length(s) * 2.0 - tt * 1.2 - u_bassAccum);
            v *= 0.25;
            float ln = abs(fract(v * u_plasmaLines + u_time * 0.05) - 0.5) * 2.0;
            float I = 1.0 - smoothstep(0.0, 0.10, ln);
            ink += pal(phase + v * 0.5 * spread + 0.3, U) * I * u_plasmaAmt * (0.2 + 0.9 * u_mid);
        }

        // Concentric polygons that pulse with the bass
        if (u_shapeAmt > 0.001) {
            float n = max(u_shapeSides, 3.0);
            float segA = 6.2831853 / n;
            for (int i = 0; i < 4; i++) {
                float fi = float(i);
                if (fi >= u_shapeCount) break;
                float R = u_shapeSize * (0.22 + 0.2 * fi) * (1.0 + 0.4 * u_bass * (1.0 - fi * 0.2));
                float dir = (i % 2 == 0) ? 1.0 : -1.0;
                float a2 = ang + u_time * u_shapeSpin * dir * 0.3 + fi * 0.5;
                float am = a2 - segA * floor(a2 / segA) - segA * 0.5;
                float d = abs(r * cos(am) - R * cos(segA * 0.5));
                float w = 0.006 + 0.004 * u_bass;
                float I = exp(-(d * d) / (w * w));
                ink += pal(phase + 0.55 + fi * 0.12 * spread, U) * I * u_shapeAmt * (0.55 + 0.6 * u_mid);
            }
        }

        // Starburst on every beat
        if (u_burstAmt > 0.001) {
            float rays = pow(abs(sin(ang * u_burstRays * 0.5 + u_seed + u_time * 0.2)), 24.0);
            float I = rays * u_beat * smoothstep(0.03, 0.2, r) * exp(-r * 1.6) * 1.6
                    + exp(-r * r * 40.0) * u_beat * 0.7;
            ink += pal(phase + 0.8, U) * I * u_burstAmt;
        }

        // Sparks for the highs
        if (u_sparkAmt > 0.001) {
            float2 gp = p * 16.0;
            float2 cell = floor(gp);
            float tstep = floor(u_time * 12.0);
            float hsh = fract(sin(dot(cell, float2(127.1, 311.7)) + tstep * 74.7 + u_seed) * 43758.5453);
            float2 cp = fract(gp) - 0.5;
            float I = step(1.0 - 0.05 * u_treble * u_sparkAmt, hsh) * exp(-dot(cp, cp) * 70.0);
            ink += pal(phase + 0.9 + hsh * 3.0, U) * I * 1.6;
        }

        ink *= u_intensity;

        // Hue-preserving accumulation: ink adds only into the headroom that is
        // left, so colours saturate instead of washing out to white.
        const float L = 1.35;
        float peak = max(col.r, max(col.g, col.b));
        col += ink * (1.0 - saturate(peak / L));
        return float4(col, 1.0);
    }

    // ---------------------------------------------------------------- bloom

    fragment float4 fs_bright(VSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        float2 px = 1.0 / float2(src.get_width(), src.get_height());
        float3 c = src.sample(sClamp, in.uv + px * float2(-1.0, -1.0)).rgb
                 + src.sample(sClamp, in.uv + px * float2( 1.0, -1.0)).rgb
                 + src.sample(sClamp, in.uv + px * float2(-1.0,  1.0)).rgb
                 + src.sample(sClamp, in.uv + px * float2( 1.0,  1.0)).rgb;
        c *= 0.25;
        float l = max(c.r, max(c.g, c.b));
        return float4(c * smoothstep(0.35, 1.1, l), 1.0);
    }

    static float3 blur9(texture2d<float> src, float2 uv, float2 dir) {
        float2 px = dir / float2(src.get_width(), src.get_height());
        float3 c = src.sample(sClamp, uv).rgb * 0.227027;
        c += (src.sample(sClamp, uv + px * 1.3846).rgb + src.sample(sClamp, uv - px * 1.3846).rgb) * 0.316216;
        c += (src.sample(sClamp, uv + px * 3.2308).rgb + src.sample(sClamp, uv - px * 3.2308).rgb) * 0.070270;
        return c;
    }

    fragment float4 fs_blur_h(VSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        return float4(blur9(src, in.uv, float2(1.6, 0.0)), 1.0);
    }

    fragment float4 fs_blur_v(VSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        return float4(blur9(src, in.uv, float2(0.0, 1.6)), 1.0);
    }

    // ---------------------------------------------------------------- composite

    fragment float4 fs_composite(VSOut in [[stage_in]],
                                 texture2d<float> sceneTex [[texture(0)]],
                                 texture2d<float> audioTex [[texture(1)]],
                                 texture2d<float> bloomTex [[texture(2)]],
                                 constant Uniforms &U [[buffer(0)]])
    {
        float2 uv = in.uv;
        float2 c = uv - 0.5;
        float ca = u_chroma * 0.012 * (1.0 + 2.0 * u_beat) * dot(c, c) * 2.0;
        float3 col;
        col.r = sceneTex.sample(sClamp, uv + c * ca).r;
        col.g = sceneTex.sample(sClamp, uv).g;
        col.b = sceneTex.sample(sClamp, uv - c * ca).b;
        col += bloomTex.sample(sClamp, uv).rgb * u_glow * 0.9;

        // Crisp equaliser overlay
        if (u_barsAmt > 0.001) {
            float2 p = float2(c.x * 2.0 * u_aspect, -c.y * 2.0);
            float4 b = barsAt(p, u_aspect, audioTex, U);
            col += barsColor(b, U) * u_barsAmt * u_intensity;
        }

        col = 1.0 - exp(-col * 1.25);
        col = mix(col, col * col * (3.0 - 2.0 * col), 0.35);

        col *= 1.0 - u_vignette * smoothstep(0.35, 1.0, length(c) * 1.25);
        col *= 1.0 - u_scan * 0.4 * (0.5 + 0.5 * sin(in.pos.y * 1.5708));
        float n = fract(sin(dot(in.pos.xy + fract(u_time) * 61.0, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        col += n * u_grain * 0.06;
        col += u_flash * 0.10;
        return float4(saturate(col), 1.0);
    }
    """
}
