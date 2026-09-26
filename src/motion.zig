//! フレーム間の動き（affine: 平行移動 + 回転 + 拡大縮小 + せん断）の推定。
//!
//! 画面を格子状のブロックに分け、隣り合うフレームで各ブロックがどこへ動いたかを ZNCC で探し、
//! そのブロックの動きに affine を当てはめる。人物など、画面全体と違う動きのブロックは外れ値として除く（RANSAC）。
//! 当てはまるブロックが足りなければ「推定できなかった」を返す（null）。そのペアで鎖を切る（temporal.zig）。
//!
//! ウォーターマークの ROI（と周りの帯）に重なるブロックは使わない。固定のウォーターマークは「動いていない」ので。
//! この module は FFmpeg に依存しない。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// RGB24 で詰めた画像
pub const Image = struct {
    width: u32,
    height: u32,
    rgb: []const u8,
};

/// x' = a x + b y + c、y' = d x + e y + f
pub const Affine = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 0,
    e: f64 = 1,
    f: f64 = 0,

    pub const identity: Affine = .{};

    pub fn translation(dx: f64, dy: f64) Affine {
        return .{ .c = dx, .f = dy };
    }

    pub fn apply(m: Affine, x: f64, y: f64) [2]f64 {
        return .{ m.a * x + m.b * y + m.c, m.d * x + m.e * y + m.f };
    }

    /// `outer ∘ inner`（先に inner、次に outer）
    pub fn compose(outer: Affine, inner: Affine) Affine {
        return .{
            .a = outer.a * inner.a + outer.b * inner.d,
            .b = outer.a * inner.b + outer.b * inner.e,
            .c = outer.a * inner.c + outer.b * inner.f + outer.c,
            .d = outer.d * inner.a + outer.e * inner.d,
            .e = outer.d * inner.b + outer.e * inner.e,
            .f = outer.d * inner.c + outer.e * inner.f + outer.f,
        };
    }

    /// 逆変換。行列部分が特異なら null
    pub fn inverse(m: Affine) ?Affine {
        const det = m.a * m.e - m.b * m.d;
        if (@abs(det) < 1e-12) return null;
        // 平行移動だけなら、割り算をせずに符号だけ返す（整数の移動が整数のまま保たれる）
        if (m.a == 1 and m.b == 0 and m.d == 0 and m.e == 1) return translation(-m.c, -m.f);
        const ia = m.e / det;
        const ib = -m.b / det;
        const id = -m.d / det;
        const ie = m.a / det;
        return .{ .a = ia, .b = ib, .c = -(ia * m.c + ib * m.f), .d = id, .e = ie, .f = -(id * m.c + ie * m.f) };
    }
};

pub const Estimate = struct {
    /// 前のフレームの点 p が、次のフレームでは motion(p) に写る
    motion: Affine,
    /// affine に当てはまったブロック数 / 動きを測れたブロック数
    inliers: u32,
    blocks: u32,
    /// 当てはまったブロックの残差の二乗平均平方根（px）
    rms: f64,
};

pub const Params = struct {
    /// 格子のブロック数（横 x 縦）
    grid_x: u32 = 6,
    grid_y: u32 = 4,
    /// ブロックが「当てはまる」とみなす残差（px）
    inlier_px: f64 = 1.0,
    /// 当てはまるブロックの最小数と最小割合
    min_inliers: u32 = 6,
    min_inlier_ratio: f64 = 0.6,
    /// ブロックを探す範囲（大まかな平行移動の周り、px）
    search: i32 = 8,
    /// ブロックの動きを信用する ZNCC の下限
    min_zncc: f64 = 0.9,
    /// ブロックの輝度の標準偏差の下限（模様が無いブロックは動きが決まらない）
    min_std: f64 = 4,
    /// ROI の周りで、ブロックに使わない幅（px）
    exclude_band: u32 = 6,
};

/// 輝度（BT.601）の平面
pub const Luma = struct {
    w: u32,
    h: u32,
    px: []f32,

    pub fn init(gpa: Allocator, img: Image) !Luma {
        const px = try gpa.alloc(f32, @as(usize, img.width) * img.height);
        for (px, 0..) |*v, i| {
            v.* = 0.299 * @as(f32, @floatFromInt(img.rgb[i * 3])) + 0.587 * @as(f32, @floatFromInt(img.rgb[i * 3 + 1])) + 0.114 * @as(f32, @floatFromInt(img.rgb[i * 3 + 2]));
        }
        return .{ .w = img.width, .h = img.height, .px = px };
    }

    pub fn deinit(l: Luma, gpa: Allocator) void {
        gpa.free(l.px);
    }
};

/// 前のフレームの (bx, by) から b x b のブロックが、次のフレームで (dx, dy) ずれた所とどれだけ似ているか（ZNCC）。
/// `step` 画素おきに見る
fn blockZncc(prev: Luma, cur: Luma, bx: u32, by: u32, b: u32, dx: i32, dy: i32, step: u32) ?f64 {
    const x0 = @as(i64, bx) + dx;
    const y0 = @as(i64, by) + dy;
    if (x0 < 0 or y0 < 0 or x0 + b > cur.w or y0 + b > cur.h) return null;
    var sa: f64 = 0;
    var sb: f64 = 0;
    var saa: f64 = 0;
    var sbb: f64 = 0;
    var sab: f64 = 0;
    var n: f64 = 0;
    var y: u32 = 0;
    while (y < b) : (y += step) {
        var x: u32 = 0;
        while (x < b) : (x += step) {
            const va: f64 = prev.px[(by + y) * prev.w + bx + x];
            const vb: f64 = cur.px[@as(usize, @intCast(y0 + y)) * cur.w + @as(usize, @intCast(x0 + x))];
            sa += va;
            sb += vb;
            saa += va * va;
            sbb += vb * vb;
            sab += va * vb;
            n += 1;
        }
    }
    const va = saa - sa * sa / n;
    const vb = sbb - sb * sb / n;
    if (va <= 1e-9 or vb <= 1e-9) return null;
    return (sab - sa * sb / n) / @sqrt(va * vb);
}

fn blockStd(l: Luma, bx: u32, by: u32, b: u32, step: u32) f64 {
    var s: f64 = 0;
    var ss: f64 = 0;
    var n: f64 = 0;
    var y: u32 = 0;
    while (y < b) : (y += step) {
        var x: u32 = 0;
        while (x < b) : (x += step) {
            const v: f64 = l.px[(by + y) * l.w + bx + x];
            s += v;
            ss += v * v;
            n += 1;
        }
    }
    return @sqrt(@max(0, ss / n - (s / n) * (s / n)));
}

/// 放物線で頂点の位置（-0.5..0.5）を出す
fn parabola(l: f64, c: f64, r: f64) f64 {
    const den = l - 2 * c + r;
    if (@abs(den) < 1e-12) return 0;
    return std.math.clamp(0.5 * (l - r) / den, -0.5, 0.5);
}

const Vector = struct { px: f64, py: f64, qx: f64, qy: f64 };

/// 隣り合うフレームの affine を推定する。`coarse` は大まかな平行移動（位相相関の結果）。
/// 当てはまるブロックが足りなければ null（推定できなかった）
pub fn estimateAffine(gpa: Allocator, prev: Luma, cur: Luma, exclude: ?Rect, coarse: [2]i32, p: Params) !?Estimate {
    const w = prev.w;
    const h = prev.h;
    // ブロックの大きさ: 画面の短い辺の 1/6（32〜128 px）。大きいほど模様が入って動きが決まりやすい
    const b: u32 = std.math.clamp(@min(w, h) / 6, 32, 128);
    const step: u32 = if (b > 64) 2 else 1;
    const margin: i64 = @as(i64, p.search) + @max(@abs(coarse[0]), @abs(coarse[1]));

    var vectors: std.ArrayList(Vector) = .empty;
    defer vectors.deinit(gpa);
    for (0..p.grid_y) |gy| for (0..p.grid_x) |gx| {
        // ブロックの左上。画面の端から margin 離して均等に置く
        const span_x = @as(i64, w) - 2 * margin - b;
        const span_y = @as(i64, h) - 2 * margin - b;
        if (span_x <= 0 or span_y <= 0) continue;
        const bx: u32 = @intCast(margin + @divTrunc(span_x * @as(i64, @intCast(gx)), @max(1, p.grid_x - 1)));
        const by: u32 = @intCast(margin + @divTrunc(span_y * @as(i64, @intCast(gy)), @max(1, p.grid_y - 1)));
        if (exclude) |r| {
            // ROI（と帯）に、探す範囲を含めて重なるブロックは使わない
            const e: i64 = @as(i64, p.exclude_band) + margin;
            const overlap = @as(i64, bx) < @as(i64, r.x) + r.w + e and @as(i64, bx) + b + e > r.x and
                @as(i64, by) < @as(i64, r.y) + r.h + e and @as(i64, by) + b + e > r.y;
            if (overlap) continue;
        }
        if (blockStd(prev, bx, by, b, step) < p.min_std) continue;

        var best: f64 = -2;
        var bdx: i32 = 0;
        var bdy: i32 = 0;
        var dy: i32 = coarse[1] - p.search;
        while (dy <= coarse[1] + p.search) : (dy += 1) {
            var dx: i32 = coarse[0] - p.search;
            while (dx <= coarse[0] + p.search) : (dx += 1) {
                const z = blockZncc(prev, cur, bx, by, b, dx, dy, step) orelse continue;
                if (z > best) {
                    best = z;
                    bdx = dx;
                    bdy = dy;
                }
            }
        }
        if (best < p.min_zncc) continue;
        // 探す範囲の端で最大なら、本当の位置は外にあるかもしれない
        if (@abs(bdx - coarse[0]) == p.search or @abs(bdy - coarse[1]) == p.search) continue;
        const sx = parabola(blockZncc(prev, cur, bx, by, b, bdx - 1, bdy, step) orelse best, best, blockZncc(prev, cur, bx, by, b, bdx + 1, bdy, step) orelse best);
        const sy = parabola(blockZncc(prev, cur, bx, by, b, bdx, bdy - 1, step) orelse best, best, blockZncc(prev, cur, bx, by, b, bdx, bdy + 1, step) orelse best);
        const cx = @as(f64, @floatFromInt(bx)) + @as(f64, @floatFromInt(b)) / 2;
        const cy = @as(f64, @floatFromInt(by)) + @as(f64, @floatFromInt(b)) / 2;
        try vectors.append(gpa, .{ .px = cx, .py = cy, .qx = cx + @as(f64, @floatFromInt(bdx)) + sx, .qy = cy + @as(f64, @floatFromInt(bdy)) + sy });
    };
    return fitRansac(vectors.items, p);
}

/// 3 点の組をすべて試して、当てはまるブロックが最も多い affine を選び、当てはまったブロックで最小二乗で当て直す。
/// 乱数を使わないので結果は毎回同じ
fn fitRansac(v: []const Vector, p: Params) ?Estimate {
    const n = v.len;
    if (n < @max(3, p.min_inliers)) return null;
    var best_in: u32 = 0;
    var best_err: f64 = std.math.inf(f64);
    var best: Affine = .identity;
    for (0..n) |i| for (i + 1..n) |j| for (j + 1..n) |k| {
        const m = solve3(v[i], v[j], v[k]) orelse continue;
        var cnt: u32 = 0;
        var err: f64 = 0;
        for (v) |q| {
            const e = residual(m, q);
            if (e < p.inlier_px) {
                cnt += 1;
                err += e * e;
            }
        }
        if (cnt > best_in or (cnt == best_in and err < best_err)) {
            best_in = cnt;
            best_err = err;
            best = m;
        }
    };
    if (best_in < p.min_inliers or @as(f64, @floatFromInt(best_in)) < p.min_inlier_ratio * @as(f64, @floatFromInt(n))) return null;

    // 当てはまったブロックで最小二乗
    var in_buf: [256]Vector = undefined;
    var m_in: usize = 0;
    for (v) |q| if (residual(best, q) < p.inlier_px and m_in < in_buf.len) {
        in_buf[m_in] = q;
        m_in += 1;
    };
    const fitted = leastSquares(in_buf[0..m_in]) orelse best;
    var sse: f64 = 0;
    var cnt: u32 = 0;
    for (v) |q| {
        const e = residual(fitted, q);
        if (e < p.inlier_px) {
            sse += e * e;
            cnt += 1;
        }
    }
    if (cnt < p.min_inliers or @as(f64, @floatFromInt(cnt)) < p.min_inlier_ratio * @as(f64, @floatFromInt(n))) return null;
    return .{ .motion = fitted, .inliers = cnt, .blocks = @intCast(n), .rms = @sqrt(sse / @as(f64, @floatFromInt(cnt))) };
}

fn residual(m: Affine, q: Vector) f64 {
    const r = m.apply(q.px, q.py);
    return @sqrt((r[0] - q.qx) * (r[0] - q.qx) + (r[1] - q.qy) * (r[1] - q.qy));
}

/// 3 点から affine を解く。3 点がほぼ一直線なら null
fn solve3(p0: Vector, p1: Vector, p2: Vector) ?Affine {
    return leastSquares(&.{ p0, p1, p2 });
}

/// 最小二乗で affine を当てる（x' と y' で別々に 3 変数の正規方程式）
fn leastSquares(v: []const Vector) ?Affine {
    if (v.len < 3) return null;
    // 数値を安定させるため重心を原点にする
    var mx: f64 = 0;
    var my: f64 = 0;
    for (v) |q| {
        mx += q.px;
        my += q.py;
    }
    mx /= @floatFromInt(v.len);
    my /= @floatFromInt(v.len);
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var syy: f64 = 0;
    var sx_qx: f64 = 0;
    var sy_qx: f64 = 0;
    var s_qx: f64 = 0;
    var sx_qy: f64 = 0;
    var sy_qy: f64 = 0;
    var s_qy: f64 = 0;
    for (v) |q| {
        const x = q.px - mx;
        const y = q.py - my;
        sxx += x * x;
        sxy += x * y;
        syy += y * y;
        sx_qx += x * q.qx;
        sy_qx += y * q.qx;
        s_qx += q.qx;
        sx_qy += x * q.qy;
        sy_qy += y * q.qy;
        s_qy += q.qy;
    }
    const nn: f64 = @floatFromInt(v.len);
    const det = sxx * syy - sxy * sxy;
    // 点がほぼ一直線（面積が小さい）なら解かない
    if (det < 1e-6 * (sxx + syy) * (sxx + syy) or det < 1) return null;
    const a = (sx_qx * syy - sy_qx * sxy) / det;
    const b = (sy_qx * sxx - sx_qx * sxy) / det;
    const d = (sx_qy * syy - sy_qy * sxy) / det;
    const e = (sy_qy * sxx - sx_qy * sxy) / det;
    const c0 = s_qx / nn;
    const f0 = s_qy / nn;
    // 重心を戻す: x' = a (x - mx) + b (y - my) + c0
    return .{ .a = a, .b = b, .c = c0 - a * mx - b * my, .d = d, .e = e, .f = f0 - d * mx - e * my };
}

// ---- tests -------------------------------------------------------------------

test "motion: compose and inverse" {
    const m: Affine = .{ .a = 1.01, .b = -0.02, .c = 5, .d = 0.02, .e = 1.01, .f = -3 };
    const inv = m.inverse().?;
    const p = inv.apply(m.apply(123, 45)[0], m.apply(123, 45)[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 123), p[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 45), p[1], 1e-9);
    const t = Affine.translation(3, -2).compose(Affine.translation(4, 1));
    try std.testing.expectEqual(Affine.translation(7, -1), t);
    // 平行移動の逆は割り算をしない（整数の移動が整数のまま）
    try std.testing.expectEqual(Affine.translation(-7, 1), t.inverse().?);
}

test "motion: least squares recovers an exact affine, and RANSAC ignores a block that moves on its own" {
    const truth: Affine = .{ .a = 1.02, .b = -0.01, .c = 4, .d = 0.015, .e = 0.99, .f = -2 };
    var v: [12]Vector = undefined;
    for (&v, 0..) |*q, i| {
        const x: f64 = @floatFromInt(40 + 50 * (i % 4));
        const y: f64 = @floatFromInt(30 + 60 * (i / 4));
        const r = truth.apply(x, y);
        q.* = .{ .px = x, .py = y, .qx = r[0], .qy = r[1] };
    }
    // 2 つのブロックだけ別の動き（人物が横切った）
    v[3].qx += 15;
    v[7].qy -= 9;
    const est = fitRansac(&v, .{}).?;
    try std.testing.expectEqual(@as(u32, 10), est.inliers);
    try std.testing.expectApproxEqAbs(truth.a, est.motion.a, 1e-9);
    try std.testing.expectApproxEqAbs(truth.c, est.motion.c, 1e-7);
    try std.testing.expectApproxEqAbs(truth.e, est.motion.e, 1e-9);
    try std.testing.expect(est.rms < 1e-6);
}

test "motion: too few consistent blocks means not estimated" {
    // 12 ブロックがばらばらに動く（1 つの affine で説明できない）
    var v: [12]Vector = undefined;
    var prng: std.Random.DefaultPrng = .init(4);
    for (&v, 0..) |*q, i| {
        const x: f64 = @floatFromInt(40 + 50 * (i % 4));
        const y: f64 = @floatFromInt(30 + 60 * (i / 4));
        q.* = .{ .px = x, .py = y, .qx = x + prng.random().float(f64) * 20 - 10, .qy = y + prng.random().float(f64) * 20 - 10 };
    }
    try std.testing.expectEqual(@as(?Estimate, null), fitRansac(&v, .{}));
}

/// 大きな乱数模様（4x4 ブロックで塗って滑らかにしたもの）を、affine で写した輝度の画像を作る
fn warpedScene(gpa: Allocator, w: u32, h: u32, m: Affine, seed: u64) !Luma {
    var prng: std.Random.DefaultPrng = .init(seed);
    const sw = 1024;
    const tex = try gpa.alloc(f32, sw * sw);
    defer gpa.free(tex);
    const cells = try gpa.alloc(f32, (sw / 4) * (sw / 4));
    defer gpa.free(cells);
    for (cells) |*c| c.* = prng.random().float(f32) * 255;
    for (0..sw) |y| for (0..sw) |x| {
        tex[y * sw + x] = cells[(y / 4) * (sw / 4) + x / 4];
    };
    const px = try gpa.alloc(f32, @as(usize, w) * h);
    // 出力の (x, y) は、模様の m^-1(x, y)（m で動いた後の画像）
    const inv = m.inverse().?;
    for (0..h) |y| for (0..w) |x| {
        const s = inv.apply(@floatFromInt(x), @floatFromInt(y));
        const sx: usize = @intFromFloat(std.math.clamp(s[0] + 300, 0, sw - 1));
        const sy: usize = @intFromFloat(std.math.clamp(s[1] + 300, 0, sw - 1));
        px[y * w + x] = tex[sy * sw + sx];
    };
    return .{ .w = w, .h = h, .px = px };
}

test "motion: estimateAffine finds a small zoom and rotation between two frames" {
    const gpa = std.testing.allocator;
    const a = try warpedScene(gpa, 320, 240, .identity, 11);
    defer a.deinit(gpa);
    // 中央 (160, 120) を中心に 1% 拡大し、0.5 度回す
    const ang = 0.5 * std.math.pi / 180.0;
    const s = 1.01;
    const center = Affine.translation(160, 120);
    const rot: Affine = .{ .a = s * @cos(ang), .b = -s * @sin(ang), .d = s * @sin(ang), .e = s * @cos(ang) };
    const truth = center.compose(rot).compose(Affine.translation(-160, -120));
    const b = try warpedScene(gpa, 320, 240, truth, 11);
    defer b.deinit(gpa);
    const est = (try estimateAffine(gpa, a, b, .{ .x = 130, .y = 100, .w = 60, .h = 40 }, .{ 0, 0 }, .{})).?;
    // 画面の四隅で、推定と正解の写し先の差が 1 px 未満
    for ([_][2]f64{ .{ 0, 0 }, .{ 319, 0 }, .{ 0, 239 }, .{ 319, 239 } }) |c| {
        const pe = est.motion.apply(c[0], c[1]);
        const pt = truth.apply(c[0], c[1]);
        try std.testing.expect(@abs(pe[0] - pt[0]) < 1 and @abs(pe[1] - pt[1]) < 1);
    }
}
