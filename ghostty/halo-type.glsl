// halo-type.glsl — Ghostty custom shader (Halo): typing impacts + the Return explosion.
//
// Typing (every key that moves the cursor), ~0.4s: the input box lines (─────) light up in a soft
//   pool centred on the cursor, with a faint glow at the cursor; it follows you while you type and
//   fades when you stop. Colour = the cursor colour, which Halo sets to the project's identity colour.
// Return, ~1.1s: a supernova. The terminal shakes, a shockwave with a rainbow crest sweeps the
//   whole window and bends the text as it passes, the screen flashes, sparks fly out of the
//   cursor and fall, and the input box lines blaze. Halo signals it by turning the cursor
//   white-hot: #ffffBB, where BB counts down from ff to 00 = the explosion clock.
// Ctrl+U, 0.3s: a strike-through slashes across the erased line and retracts into the cursor.
// Paste, 0.55s: the pasted text is beamed in behind a scan beam, flickering in like a decoding signal.
// Ghostty's animation loop is off (custom-shader-animation = false): Halo makes Ghostty draw
// frames only while an effect runs, so idle terminals cost nothing.

const float BOOM = 1.1;

float hash(float n) { return fract(sin(n * 127.1) * 43758.5453); }

vec3 rainbow(float h) { return 0.5 + 0.5 * cos(6.28318 * (h + vec3(0.0, 0.33, 0.67))); }

float inkAt(vec2 p) {
    vec3 c = texture(iChannel0, p / iResolution.xy).rgb;
    return step(0.12, distance(c, iBackgroundColor));
}

// A pixel of a thin horizontal line: ink left and right of it, background above and below.
float lineAt(vec2 p) {
    return inkAt(p) * inkAt(p + vec2(5.0, 0.0)) * inkAt(p - vec2(5.0, 0.0))
         * (1.0 - inkAt(p + vec2(0.0, 5.0))) * (1.0 - inkAt(p - vec2(0.0, 5.0)));
}

// The identity's hue at full brightness, from the project background Halo gave the terminal.
vec3 bgAccent() {
    vec3 bg = iBackgroundColor;
    return bg / max(max(bg.r, bg.g), max(bg.b, 0.001));
}

// Middle of the text row the cursor is on (works for underline, bar and block cursors; y is up).
float rowMid(vec4 c) {
    float h = max(c.w, max(iCurrentCursor.z, 1.0) * 2.0);
    return c.y - c.w + h * 0.5;
}

vec2 cursorCenter() {
    // xy is the top-left corner of the cursor (y up), zw its size
    return vec2(iCurrentCursor.x + max(iCurrentCursor.z, 1.0) * 0.5, iCurrentCursor.y - iCurrentCursor.w * 0.5);
}

vec4 typing(vec4 base, vec2 fragCoord) {
    float t = iTime - iTimeCursorChange;
    if (t < 0.0 || t > 0.4) return base;
    // a colour-only change (Halo handing the cursor its colour back after a Return) is not a keystroke
    if (all(lessThan(abs(iCurrentCursor.xy - iPreviousCursor.xy), vec2(0.5)))) return base;
    float cellW = max(iCurrentCursor.z, 1.0);
    float cellH = max(iCurrentCursor.w, cellW * 2.0);
    vec2 d = fragCoord - cursorCenter();
    if (abs(d.x) > 300.0 || abs(d.y) > cellH * 2.5) return base; // the light lives right around the cursor

    vec3 accent = iCurrentCursorColor.rgb;
    float k = 1.0 - smoothstep(0.0, 0.4, t);
    // the box lines light up under your fingers, a soft pool of light centred on the cursor column
    float pool = exp(-d.x * d.x / (2.0 * 120.0 * 120.0)) * k;
    vec3 add = accent * lineAt(fragCoord) * pool;
    // and a faint glow at the cursor itself
    add += accent * exp(-dot(d, d) / (cellW * cellW * 3.0)) * k * 0.35;

    float a = max(base.a, clamp(max(add.r, max(add.g, add.b)), 0.0, 1.0));
    return vec4(base.rgb + add, a);
}

vec4 boom(vec2 fragCoord, float t) {
    vec2 res = iResolution.xy;
    vec3 bg = iBackgroundColor;
    vec3 accent = bg / max(max(bg.r, bg.g), max(bg.b, 0.001)); // the identity's hue at full brightness
    vec2 o = cursorCenter();
    float cellW = max(iCurrentCursor.z, 1.0);
    float cellH = max(iCurrentCursor.w, cellW * 2.0);
    float fade = 1.0 - t / BOOM;

    // 1. the whole terminal shakes
    vec2 p = fragCoord + vec2(sin(t * 95.0), cos(t * 83.0)) * 7.0 * exp(-t * 9.0);

    // 2. a shockwave sweeps the window, bending the text, with a chromatic edge
    vec2 d = p - o;
    float dist = length(d);
    vec2 dir = d / max(dist, 1.0);
    float R = (1.0 - pow(1.0 - min(t / 0.9, 1.0), 3.0)) * length(res) * 1.05;
    float band = (dist - R) / 70.0;
    float wave = exp(-band * band) * fade;
    float push = 26.0 * wave;
    vec4 base = texture(iChannel0, (p - dir * push) / res);
    float cr = texture(iChannel0, (p - dir * push * 1.35) / res).r;
    float cb = texture(iChannel0, (p - dir * push * 0.65) / res).b;
    vec3 col = vec3(cr, base.g, cb);

    vec3 add = vec3(0.0);
    float crest = exp(-pow((dist - R) / 10.0, 2.0)) * fade;
    add += mix(vec3(1.0), rainbow(dist / 900.0 - t), 0.55) * crest * 0.9;
    add += accent * wave * 0.25;

    // 3. a white-hot core cooling through the identity colour
    float core = exp(-dist / (cellW * (3.0 + t * 25.0))) * exp(-t * 6.0);
    add += mix(vec3(1.0), accent, min(t * 4.0, 1.0)) * core * 2.0;

    // 4. the whole screen flashes
    add += accent * 0.32 * exp(-t * 9.0) + vec3(0.12) * exp(-t * 22.0);

    // 5. sparks fly out of the cursor and fall
    for (int i = 0; i < 32; i++) {
        float fi = float(i);
        float ang = hash(fi) * 6.28318;
        float speed = 350.0 + 1100.0 * hash(fi + 11.3);
        float tt = t * (0.8 + 0.4 * hash(fi + 3.7));
        vec2 sp = o + vec2(cos(ang), sin(ang)) * speed * tt * (1.0 - 0.45 * tt) - vec2(0.0, 520.0 * tt * tt);
        float sd = length(p - sp);
        float life = max(0.0, 1.0 - tt / 0.95);
        add += mix(accent, rainbow(hash(fi + 5.1)), 0.6) * life * life * 2.5 / (1.0 + sd * sd * 0.12);
    }

    // 6. the input box lines blaze, with two pulses racing outward
    float near = 1.0 - smoothstep(cellH * 4.0, cellH * 9.0, abs(p.y - o.y));
    if (near > 0.0) {
        float dx = abs(p.x - o.x);
        float pulse = exp(-pow((dx - t * 4200.0) / 120.0, 2.0)) + exp(-pow((dx - t * 2600.0) / 90.0, 2.0));
        float energy = near * (pulse * 1.5 + exp(-t * 3.0)) * exp(-t * 1.8);
        add += (vec3(0.6) + accent) * lineAt(p) * energy;
    }

    float a = max(base.a, clamp(max(add.r, max(add.g, add.b)), 0.0, 1.0));
    return vec4(col + add, a);
}

// Ctrl+U (Halo turns the cursor #ff00ff): Claude has already cleared the line, so a strike-through
// slashes across where the text was, over a fading afterimage, then retracts into the cursor. 0.3s.
vec4 erase(vec4 base, vec2 fragCoord, float t) {
    if (t < 0.0 || t > 0.3) return base;
    float cellW = max(iCurrentCursor.z, 1.0);
    float h = max(iCurrentCursor.w, cellW * 2.0);
    float dy = fragCoord.y - rowMid(iCurrentCursor);
    if (abs(dy) > h) return base;
    float x0 = iCurrentCursor.x;                         // the line now starts here
    float x1 = iPreviousCursor.x + cellW;                // the erased text ended here
    if (abs(iPreviousCursor.y - iCurrentCursor.y) > 0.5 || x1 < x0 + cellW * 2.0) x1 = x0 + cellW * 24.0;
    float x = fragCoord.x;
    float right = t < 0.11 ? mix(x0, x1, smoothstep(0.0, 0.11, t))   // slash out
                           : mix(x1, x0, smoothstep(0.11, 0.27, t)); // retract into the cursor
    float inside = step(x0 - 1.0, x) * step(x, right);
    vec3 accent = bgAccent();
    float strike = exp(-dy * dy / 1.5) + exp(-dy * dy / 20.0) * 0.45;
    vec3 add = (vec3(1.0) * 0.8 + accent * 0.6) * strike * inside;
    float ghost = step(x0, x) * step(x, x1) * step(abs(dy), h * 0.45) * (1.0 - smoothstep(0.0, 0.2, t));
    add += accent * ghost * 0.14;
    float spark = exp(-pow((t - 0.27) / 0.025, 2.0)) * exp(-length(vec2(x - x0, dy)) / cellW);
    add += mix(vec3(1.0), accent, 0.4) * spark * 1.6;
    float a = max(base.a, clamp(max(add.r, max(add.g, add.b)), 0.0, 1.0));
    return vec4(base.rgb + add, a);
}

// Paste (Halo turns the cursor #00ffff): the pasted text is beamed in. A scan beam sweeps from where
// the paste started to where it ended; text ahead of it is held dark, text behind it flickers in like
// a decoding signal with a cyan holographic glow, then settles. 0.55s.
vec4 pasteIn(vec4 base, vec2 fragCoord, float t) {
    if (t < 0.0 || t > 0.55) return base;
    float cellW = max(iCurrentCursor.z, 1.0);
    float h = max(iCurrentCursor.w, cellW * 2.0);
    float yS = rowMid(iPreviousCursor), yE = rowMid(iCurrentCursor);
    vec2 p = fragCoord;
    if (p.y > max(yS, yE) + h * 0.5 || p.y < min(yS, yE) - h * 0.5) return base;
    bool first = abs(p.y - yS) <= h * 0.5, last = abs(p.y - yE) <= h * 0.5;
    float xs = iPreviousCursor.x, xe = iCurrentCursor.x;
    if (first && last && !(p.x >= xs && p.x <= xe)) return base;
    if (first && !last && p.x < xs) return base;
    if (last && !first && p.x > xe) return base;
    bool oneRow = first && last;
    float x0 = oneRow ? xs : 0.0, x1 = oneRow ? xe : iResolution.x;
    float u = clamp((p.x - x0) / max(x1 - x0, 1.0), 0.0, 1.0);     // 0..1 along the sweep
    float sweep = smoothstep(0.0, 0.24, t);
    float since = t - 0.24 * u;                                   // time since the beam passed here
    vec3 holo = mix(vec3(0.55, 1.0, 1.0), bgAccent(), 0.3);
    float ink = step(0.12, distance(base.rgb, iBackgroundColor));
    vec3 col = base.rgb;
    vec3 add = vec3(0.0);
    if (u > sweep) {
        col = mix(col, col * 0.2, ink);                             // not beamed in yet
    } else {
        float cell = floor(p.x / cellW) * 7.13 + floor(p.y / h) * 3.71;
        float flicker = step(0.45, fract(sin((cell + floor(t * 45.0)) * 91.7) * 4375.5));
        float decoding = 1.0 - smoothstep(0.0, 0.09, since);
        col = mix(col, col * (0.35 + 0.9 * flicker), ink * decoding);
        add += holo * ink * exp(-since * 9.0) * 0.9;
    }
    float beam = exp(-pow((p.x - mix(x0, x1, sweep)) / 3.0, 2.0)) * (1.0 - smoothstep(0.24, 0.32, t));
    add += holo * beam * 1.4 + vec3(beam * 0.4);
    float a = max(base.a, clamp(max(add.r, max(add.g, add.b)), 0.0, 1.0));
    return vec4(col + add, a);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;
    if (iFocus == 0) return;
    vec3 cc = iCurrentCursorColor.rgb;
    if (cc.r > 0.985 && cc.g > 0.985) { // Halo's Return marker
        float t = (1.0 - cc.b) * BOOM;
        if (t < BOOM) fragColor = boom(fragCoord, t);
        return;
    }
    float since = iTime - iTimeCursorChange;
    if (cc.r > 0.985 && cc.g < 0.02 && cc.b > 0.985) { fragColor = erase(base, fragCoord, since); return; }   // Ctrl+U
    if (cc.r < 0.02 && cc.g > 0.985 && cc.b > 0.985) { fragColor = pasteIn(base, fragCoord, since); return; } // paste
    // Typing impacts only in Claude windows Halo manages (they have the project background;
    // other windows keep the config background #060616 from ~/.config/ghostty/config).
    if (distance(iBackgroundColor, vec3(6.0, 6.0, 22.0) / 255.0) < 0.006) return;
    fragColor = typing(base, fragCoord);
}
