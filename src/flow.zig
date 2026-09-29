//! 局所の dense optical flow（ピラミッド型の Lucas–Kanade）。ROI の周りの小さな範囲だけで求める（docs/adr/0018）。
//!
//! - 輝度の面（Plane）どうしで、a の各画素が b のどこに写るか（a(x) ≈ b(x + f(x))）を求める
//! - 粗い段から細かい段へ。各段で、画素ごとに 7x7 の窓の構造テンソルで数回更新し、3x3 の中央値でならしてから次の段へ
//! - ウォーターマークの下の flow は当てにならない（止まった文字の flow は 0）ので、`complete` で周りから補う
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");

pub const Region = struct { x: u32, y: u32, w: u32, h: u32 };

/// 輝度（0〜255 の小数）の面
pub const Plane = struct {
    w: u32,
    h: u32,
    px: []f32,

    pub fn deinit(p: Plane, gpa: std.mem.Allocator) void {
        gpa.free(p.px);
    }

    fn at(p: Plane, x: i64, y: i64) f32 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, p.w) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, p.h) - 1));
        return p.px[cy * p.w + cx];
    }

    /// 双線形補間（画面の外は端の値）
    pub fn sample(p: Plane, x: f32, y: f32) f32 {
        const x0 = @floor(x);
        const y0 = @floor(y);
        const tx = x - x0;
        const ty = y - y0;
        const ix: i64 = @intFromFloat(x0);
        const iy: i64 = @intFromFloat(y0);
        return (1 - ty) * ((1 - tx) * p.at(ix, iy) + tx * p.at(ix + 1, iy)) + ty * ((1 - tx) * p.at(ix, iy + 1) + tx * p.at(ix + 1, iy + 1));
    }
};

/// RGB24 の画像（幅 img_w）の `r` の範囲の輝度（BT.601 の重み）
pub fn lumaOf(gpa: std.mem.Allocator, rgb: []const u8, img_w: u32, r: Region) !Plane {
    const px = try gpa.alloc(f32, @as(usize, r.w) * r.h);
    for (0..r.h) |y| for (0..r.w) |x| {
        const i = ((r.y + y) * img_w + r.x + x) * 3;
        px[y * r.w + x] = 0.299 * @as(f32, @floatFromInt(rgb[i])) + 0.587 * @as(f32, @floatFromInt(rgb[i + 1])) + 0.114 * @as(f32, @floatFromInt(rgb[i + 2]));
    };
    return .{ .w = r.w, .h = r.h, .px = px };
}

/// 範囲の画素ごとの動き（範囲の座標、px）
pub const Field = struct {
    w: u32,
    h: u32,
    u: []f32,
    v: []f32,

    pub fn deinit(f: Field, gpa: std.mem.Allocator) void {
        gpa.free(f.u);
        gpa.free(f.v);
    }

    pub fn sample(f: Field, x: f32, y: f32) [2]f32 {
        const pu: Plane = .{ .w = f.w, .h = f.h, .px = f.u };
        const pv: Plane = .{ .w = f.w, .h = f.h, .px = f.v };
        return .{ pu.sample(x, y), pv.sample(x, y) };
    }
};

pub const Params = struct {
    levels: u32 = 4,
    /// 窓の半径（7x7 なら 3）
    radius: u32 = 3,
    iterations: u32 = 4,
};

fn downsample(gpa: std.mem.Allocator, p: Plane) !Plane {
    const w = @max(1, p.w / 2);
    const h = @max(1, p.h / 2);
    const px = try gpa.alloc(f32, @as(usize, w) * h);
    for (0..h) |y| for (0..w) |x| {
        const ix: i64 = @intCast(2 * x);
        const iy: i64 = @intCast(2 * y);
        px[y * w + x] = (p.at(ix, iy) + p.at(ix + 1, iy) + p.at(ix, iy + 1) + p.at(ix + 1, iy + 1)) / 4;
    };
    return .{ .w = w, .h = h, .px = px };
}

fn downsampleMask(gpa: std.mem.Allocator, m: []const bool, w: u32, h: u32) ![]bool {
    const nw = @max(1, w / 2);
    const nh = @max(1, h / 2);
    const out = try gpa.alloc(bool, @as(usize, nw) * nh);
    for (0..nh) |y| for (0..nw) |x| {
        var any = false;
        for (0..2) |dy| for (0..2) |dx| {
            const xx = @min(2 * x + dx, w - 1);
            const yy = @min(2 * y + dy, h - 1);
            any = any or m[yy * w + xx];
        };
        out[y * nw + x] = any;
    };
    return out;
}

/// a の各画素が b のどこに写るか。`ignore`（true = 当てにならない、止まったウォーターマークなど）の画素は、
/// 窓の計算（構造テンソルと差の和）に使わない。粗い段では窓が広く覆うので、外さないと止まった画素に flow が引っぱられた
pub fn dense(gpa: std.mem.Allocator, a: Plane, b: Plane, ignore: ?[]const bool, p: Params) !Field {
    std.debug.assert(a.w == b.w and a.h == b.h);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // ピラミッド（0 = 元の大きさ）。小さすぎる段は作らない
    var pa: [8]Plane = undefined;
    var pb: [8]Plane = undefined;
    pa[0] = a;
    pb[0] = b;
    var pm: [8]?[]const bool = .{null} ** 8;
    pm[0] = ignore;
    var levels: usize = 1;
    while (levels < @min(p.levels, 8) and pa[levels - 1].w >= 16 and pa[levels - 1].h >= 16) : (levels += 1) {
        pa[levels] = try downsample(arena, pa[levels - 1]);
        pb[levels] = try downsample(arena, pb[levels - 1]);
        if (pm[levels - 1]) |m| pm[levels] = try downsampleMask(arena, m, pa[levels - 1].w, pa[levels - 1].h);
    }
    var u = try arena.alloc(f32, @as(usize, pa[levels - 1].w) * pa[levels - 1].h);
    var v = try arena.alloc(f32, u.len);
    @memset(u, 0);
    @memset(v, 0);
    var li: usize = levels;
    while (li > 0) {
        li -= 1;
        const A = pa[li];
        const B = pb[li];
        const mask = pm[li];
        const n = @as(usize, A.w) * A.h;
        if (li != levels - 1) {
            // 1 つ粗い段の flow を 2 倍して広げる
            const cw = pa[li + 1].w;
            const ch = pa[li + 1].h;
            const cu: Field = .{ .w = cw, .h = ch, .u = u, .v = v };
            const nu = try arena.alloc(f32, n);
            const nv = try arena.alloc(f32, n);
            for (0..A.h) |y| for (0..A.w) |x| {
                const s = cu.sample((@as(f32, @floatFromInt(x)) + 0.5) / 2 - 0.5, (@as(f32, @floatFromInt(y)) + 0.5) / 2 - 0.5);
                nu[y * A.w + x] = 2 * s[0];
                nv[y * A.w + x] = 2 * s[1];
            };
            u = nu;
            v = nv;
        }
        // a の勾配と、その積の積分画像（窓の和を定数時間で取る）
        const ix = try arena.alloc(f32, n);
        const iy = try arena.alloc(f32, n);
        for (0..A.h) |y| for (0..A.w) |x| {
            const xi: i64 = @intCast(x);
            const yi: i64 = @intCast(y);
            ix[y * A.w + x] = (A.at(xi + 1, yi) - A.at(xi - 1, yi)) / 2;
            iy[y * A.w + x] = (A.at(xi, yi + 1) - A.at(xi, yi - 1)) / 2;
        };
        const iw = A.w + 1;
        const sxx = try arena.alloc(f64, @as(usize, iw) * (A.h + 1));
        const sxy = try arena.alloc(f64, sxx.len);
        const syy = try arena.alloc(f64, sxx.len);
        @memset(sxx, 0);
        @memset(sxy, 0);
        @memset(syy, 0);
        for (0..A.h) |y| for (0..A.w) |x| {
            const i = y * A.w + x;
            const k = (y + 1) * iw + x + 1;
            const on: f32 = if (mask) |m| (if (m[i]) 0 else 1) else 1;
            sxx[k] = on * ix[i] * ix[i] + sxx[k - 1] + sxx[k - iw] - sxx[k - iw - 1];
            sxy[k] = on * ix[i] * iy[i] + sxy[k - 1] + sxy[k - iw] - sxy[k - iw - 1];
            syy[k] = on * iy[i] * iy[i] + syy[k - 1] + syy[k - iw] - syy[k - iw - 1];
        };
        const r: i64 = p.radius;
        const nu = try arena.alloc(f32, n);
        const nv = try arena.alloc(f32, n);
        for (0..A.h) |y| for (0..A.w) |x| {
            const i = y * A.w + x;
            const x0: usize = @intCast(@max(0, @as(i64, @intCast(x)) - r));
            const y0: usize = @intCast(@max(0, @as(i64, @intCast(y)) - r));
            const x1: usize = @intCast(@min(@as(i64, A.w), @as(i64, @intCast(x)) + r + 1));
            const y1: usize = @intCast(@min(@as(i64, A.h), @as(i64, @intCast(y)) + r + 1));
            const box = struct {
                fn f(s: []const f64, wd: usize, a0: usize, b0: usize, a1: usize, b1: usize) f64 {
                    return s[b1 * wd + a1] - s[b0 * wd + a1] - s[b1 * wd + a0] + s[b0 * wd + a0];
                }
            }.f;
            const gxx = box(sxx, iw, x0, y0, x1, y1);
            const gxy = box(sxy, iw, x0, y0, x1, y1);
            const gyy = box(syy, iw, x0, y0, x1, y1);
            const det = gxx * gyy - gxy * gxy;
            var cu = u[i];
            var cv = v[i];
            // 模様が無い（構造テンソルが退化）なら更新しない
            if (det > 1e-2 * @as(f64, @floatFromInt((x1 - x0) * (y1 - y0)))) {
                for (0..p.iterations) |_| {
                    var bx: f64 = 0;
                    var by: f64 = 0;
                    for (y0..y1) |wy| for (x0..x1) |wx| {
                        const j = wy * A.w + wx;
                        const bx_f = @as(f32, @floatFromInt(wx)) + cu;
                        const by_f = @as(f32, @floatFromInt(wy)) + cv;
                        if (mask) |m| {
                            if (m[j]) continue;
                            const rx: i64 = std.math.clamp(@as(i64, @intFromFloat(@round(bx_f))), 0, @as(i64, A.w) - 1);
                            const ry: i64 = std.math.clamp(@as(i64, @intFromFloat(@round(by_f))), 0, @as(i64, A.h) - 1);
                            if (m[@as(usize, @intCast(ry)) * A.w + @as(usize, @intCast(rx))]) continue;
                        }
                        const diff = B.sample(bx_f, by_f) - A.px[j];
                        bx += ix[j] * diff;
                        by += iy[j] * diff;
                    };
                    const du = -(gyy * bx - gxy * by) / det;
                    const dv = -(gxx * by - gxy * bx) / det;
                    cu += @floatCast(du);
                    cv += @floatCast(dv);
                    if (@abs(du) + @abs(dv) < 0.01) break;
                }
            }
            nu[i] = cu;
            nv[i] = cv;
        };
        // 3x3 の中央値でならす（外れた窓の値を抑える）
        u = try median3(arena, nu, A.w, A.h);
        v = try median3(arena, nv, A.w, A.h);
    }
    return .{ .w = a.w, .h = a.h, .u = try gpa.dupe(f32, u), .v = try gpa.dupe(f32, v) };
}

fn median3(gpa: std.mem.Allocator, src: []const f32, w: u32, h: u32) ![]f32 {
    const out = try gpa.alloc(f32, src.len);
    for (0..h) |y| for (0..w) |x| {
        var buf: [9]f32 = undefined;
        var n: usize = 0;
        for (0..3) |dy| for (0..3) |dx| {
            const yy = @as(i64, @intCast(y)) + @as(i64, @intCast(dy)) - 1;
            const xx = @as(i64, @intCast(x)) + @as(i64, @intCast(dx)) - 1;
            if (xx < 0 or yy < 0 or xx >= w or yy >= h) continue;
            buf[n] = src[@as(usize, @intCast(yy)) * w + @as(usize, @intCast(xx))];
            n += 1;
        };
        std.mem.sort(f32, buf[0..n], {}, std.sort.asc(f32));
        out[y * w + x] = buf[n / 2];
    };
    return out;
}

/// `hole`（範囲の画素ごと、true = 当てにならない）の flow を、周りの flow を境界にしたラプラス方程式で埋める
pub fn complete(f: Field, hole: []const bool, iterations: u32) void {
    std.debug.assert(hole.len == @as(usize, f.w) * f.h);
    // 初期値: 行ごとに左右の穴の外の値の平均（無ければ 0）
    for (0..f.h) |y| {
        var left: ?[2]f32 = null;
        var x: usize = 0;
        while (x < f.w) {
            const i = y * f.w + x;
            if (!hole[i]) {
                left = .{ f.u[i], f.v[i] };
                x += 1;
                continue;
            }
            var e = x;
            while (e < f.w and hole[y * f.w + e]) e += 1;
            const right: ?[2]f32 = if (e < f.w) .{ f.u[y * f.w + e], f.v[y * f.w + e] } else null;
            const val: [2]f32 = if (left != null and right != null) .{ (left.?[0] + right.?[0]) / 2, (left.?[1] + right.?[1]) / 2 } else left orelse right orelse .{ 0, 0 };
            for (x..e) |k| {
                f.u[y * f.w + k] = val[0];
                f.v[y * f.w + k] = val[1];
            }
            x = e;
        }
    }
    for (0..iterations) |_| {
        for (0..f.h) |y| for (0..f.w) |x| {
            const i = y * f.w + x;
            if (!hole[i]) continue;
            var su: f32 = 0;
            var sv: f32 = 0;
            var n: f32 = 0;
            for ([_][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
                const xx = @as(i64, @intCast(x)) + d[0];
                const yy = @as(i64, @intCast(y)) + d[1];
                if (xx < 0 or yy < 0 or xx >= f.w or yy >= f.h) continue;
                const j = @as(usize, @intCast(yy)) * f.w + @as(usize, @intCast(xx));
                su += f.u[j];
                sv += f.v[j];
                n += 1;
            }
            f.u[i] = su / n;
            f.v[i] = sv / n;
        };
    }
}

// ---- tests -------------------------------------------------------------------

/// 滑らかな模様（いくつかの正弦波の和）を (sx, sy) だけずらした面
fn texture(gpa: std.mem.Allocator, w: u32, h: u32, sx: f32, sy: f32) !Plane {
    const px = try gpa.alloc(f32, @as(usize, w) * h);
    for (0..h) |y| for (0..w) |x| {
        const fx = @as(f32, @floatFromInt(x)) - sx;
        const fy = @as(f32, @floatFromInt(y)) - sy;
        px[y * w + x] = 128 + 40 * @sin(fx / 5.0) * @cos(fy / 7.0) + 30 * @sin((fx + 2 * fy) / 11.0) + 20 * @cos((fx - fy) / 4.0);
    };
    return .{ .w = w, .h = h, .px = px };
}

fn medianError(gpa: std.mem.Allocator, f: Field, ex: f32, ey: f32, margin: u32) !f32 {
    var errs: std.ArrayList(f32) = .empty;
    defer errs.deinit(gpa);
    for (margin..f.h - margin) |y| for (margin..f.w - margin) |x| {
        const i = y * f.w + x;
        try errs.append(gpa, std.math.hypot(f.u[i] - ex, f.v[i] - ey));
    };
    std.mem.sort(f32, errs.items, {}, std.sort.asc(f32));
    return errs.items[errs.items.len / 2];
}

test "flow: finds a small and a large shift of a textured plane" {
    const gpa = std.testing.allocator;
    const a = try texture(gpa, 96, 80, 0, 0);
    defer a.deinit(gpa);
    // b は a を (dx, dy) ずらしたもの → a(x) = b(x + (dx, dy))
    for ([_][2]f32{ .{ 1.5, -0.75 }, .{ 7, 5 }, .{ -12, 3 } }) |d| {
        const b = try texture(gpa, 96, 80, d[0], d[1]);
        defer b.deinit(gpa);
        const f = try dense(gpa, a, b, null, .{});
        defer f.deinit(gpa);
        try std.testing.expect(try medianError(gpa, f, d[0], d[1], 16) < 0.2);
    }
}

test "flow: a flat plane has no motion, and complete fills a hole from its surroundings" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(f32, 40 * 30);
    defer gpa.free(px);
    @memset(px, 100);
    const flat: Plane = .{ .w = 40, .h = 30, .px = px };
    const f0 = try dense(gpa, flat, flat, null, .{});
    defer f0.deinit(gpa);
    for (f0.u, f0.v) |uu, vv| try std.testing.expect(uu == 0 and vv == 0);

    // 穴の周りが x に比例する flow（u = x / 10）なら、穴の中も同じ直線になる
    var u: [40 * 30]f32 = undefined;
    var v: [40 * 30]f32 = undefined;
    var hole = [_]bool{false} ** (40 * 30);
    for (0..30) |y| for (0..40) |x| {
        u[y * 40 + x] = @as(f32, @floatFromInt(x)) / 10;
        v[y * 40 + x] = 2;
        if (x >= 10 and x < 30 and y >= 8 and y < 22) {
            hole[y * 40 + x] = true;
            u[y * 40 + x] = 99;
            v[y * 40 + x] = -99;
        }
    };
    complete(.{ .w = 40, .h = 30, .u = &u, .v = &v }, &hole, 2000);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), u[15 * 40 + 20], 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), v[15 * 40 + 20], 0.05);
}

test "flow: pixels marked to ignore (a still watermark) do not pull the flow around them" {
    const gpa = std.testing.allocator;
    const w = 96;
    const h = 80;
    const a = try texture(gpa, w, h, 0, 0);
    defer a.deinit(gpa);
    const b = try texture(gpa, w, h, 3, 0);
    defer b.deinit(gpa);
    // 止まったブロック (40..60, 30..50) を両方に焼く
    var ignore = [_]bool{false} ** (w * h);
    for (30..50) |y| for (40..60) |x| {
        a.px[y * w + x] = 255;
        b.px[y * w + x] = 255;
        ignore[y * w + x] = true;
    };
    // ブロックの右 1 px（x = 61）の列の flow の、正解 (3, 0) からのずれの平均。
    // 実測: 外すと 0.18、外さないと 9.99（窓が止まったブロックにかかり、止まった側に引っぱられる）
    const errAt = struct {
        fn f(fl: Field) f32 {
            var sum: f32 = 0;
            for (30..50) |y| sum += std.math.hypot(fl.u[y * w + 61] - 3, fl.v[y * w + 61]);
            return sum / 20;
        }
    }.f;
    const masked = try dense(gpa, a, b, &ignore, .{});
    defer masked.deinit(gpa);
    const plain = try dense(gpa, a, b, null, .{});
    defer plain.deinit(gpa);
    try std.testing.expect(errAt(masked) < 0.3);
    try std.testing.expect(errAt(plain) > 2);
}
