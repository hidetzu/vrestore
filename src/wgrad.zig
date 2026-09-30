//! 動画全体からウォーターマークの形を推定する（`restore --mask gradient`、docs/adr/0019）。
//!
//! ウォーターマークはどのフレームでも同じ位置・同じ色で、背景はフレームごとに変わる。動画全体から取ったフレームで
//! 勾配（隣の画素との差）の時間方向の中央値を取ると、背景の勾配は打ち消し合い、ウォーターマークの勾配だけが残る
//! （Dekel et al. 2017 の最初の段）。その勾配場をポアソン方程式で積分し直すと、文字の中まで埋まったウォーターマークの像
//! （定数の差を除く）になる。範囲の外周（ROI の外）の中央値を背景の水準とし、それとの差が閾値を超えた画素を
//! ウォーターマークとして、`dilate` px 広げる（YUV 4:2:0 の色差と圧縮で、色が 1 px 外までにじむ）。
//!
//! 変わりにくさで見分ける wmask.zig と違い、背景がゆっくりしか変わらなくても、長い動画なら勾配は打ち消し合う。
//! ⚠ 短い動画（数秒）では背景の勾配が残り、背景の縁までウォーターマークと取りやすい（隠しすぎる側）。
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");
const wmask = @import("wmask.zig");

pub const Rect = wmask.Rect;

pub const Params = struct {
    /// 推定する範囲（crop）の中の ROI。範囲のうち ROI の外（周りの帯）の中央値を背景の水準にする
    inner: Rect,
    /// ウォーターマークとみなす、背景の水準との差（8 bit の明るさ、R/G/B の大きい方）。
    /// 実写 A の 5 分に焼いた 24 ケースで、大津の二値化は強さの違う 2 つの表示が並ぶと弱い方を落とし（再現率の最小 0.72）、
    /// 固定の 24 は落とさなかった（0.98、docs/SPEC.md §4）
    threshold: f32 = 24,
    /// 見分けた画素を広げる幅（px）。正解の形そのままより 1 px 広げた方が近かった（112 ケースで SSIM 0.70 → 0.80）
    dilate: u32 = 1,
    /// ポアソン方程式を解く共役勾配法の反復の上限と、残差の許容（右辺の大きさに対する比）
    max_iterations: u32 = 2000,
    tolerance: f32 = 1e-4,
    /// ROI の中で隠す割合がこの範囲の外なら、見分けられていないとして ROI 全体を隠す
    min_fraction: f32 = 0.005,
    max_fraction: f32 = 0.98,
};

pub const Result = struct {
    estimate: wmask.Estimate,
    /// ROI の中で、閾値を超えた（広げる前の）画素の割合
    roi_fraction: f32,
    /// 共役勾配法の反復回数（R/G/B の最大）
    iterations: u32,
};

/// `crops` は同じ範囲（w x h、RGB24）を動画全体から等間隔に取ったもの。3 枚以上
pub fn estimate(gpa: std.mem.Allocator, crops: []const []const u8, w: u32, h: u32, p: Params) !Result {
    std.debug.assert(crops.len >= 3 and w >= 2 and h >= 2);
    const n: usize = @as(usize, w) * h;
    const col = try gpa.alloc(f32, crops.len);
    defer gpa.free(col);
    // 各チャネルの前進差分の中央値: gx は (w-1) x h、gy は w x (h-1)
    const gx = try gpa.alloc(f32, n);
    defer gpa.free(gx);
    const gy = try gpa.alloc(f32, n);
    defer gpa.free(gy);
    const img = try gpa.alloc(f32, n * 3);
    defer gpa.free(img);
    var iterations: u32 = 0;
    for (0..3) |c| {
        @memset(gx, 0);
        @memset(gy, 0);
        for (0..h) |y| for (0..w) |x| {
            const i = y * w + x;
            if (x + 1 < w) {
                for (crops, col) |cr, *v| v.* = @as(f32, @floatFromInt(cr[(i + 1) * 3 + c])) - @as(f32, @floatFromInt(cr[i * 3 + c]));
                gx[i] = median(col);
            }
            if (y + 1 < h) {
                for (crops, col) |cr, *v| v.* = @as(f32, @floatFromInt(cr[(i + w) * 3 + c])) - @as(f32, @floatFromInt(cr[i * 3 + c]));
                gy[i] = median(col);
            }
        };
        const plane = try gpa.alloc(f32, n);
        defer gpa.free(plane);
        iterations = @max(iterations, try poisson(gpa, gx, gy, w, h, plane, p.max_iterations, p.tolerance));
        for (plane, 0..) |v, i| img[i * 3 + c] = v;
    }

    // 背景の水準: ROI の外の画素の中央値（ROI の外が無ければ範囲全体）
    var ring: std.ArrayList(f32) = .empty;
    defer ring.deinit(gpa);
    var bg: [3]f32 = undefined;
    for (0..3) |c| {
        ring.clearRetainingCapacity();
        for (0..h) |y| for (0..w) |x| {
            if (inside(p.inner, x, y)) continue;
            try ring.append(gpa, img[(y * w + x) * 3 + c]);
        };
        if (ring.items.len == 0) for (0..n) |i| try ring.append(gpa, img[i * 3 + c]);
        bg[c] = median(ring.items);
    }

    const hidden = try gpa.alloc(bool, n);
    errdefer gpa.free(hidden);
    var in_roi: usize = 0;
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        var d: f32 = 0;
        for (0..3) |c| d = @max(d, @abs(img[i * 3 + c] - bg[c]));
        hidden[i] = d > p.threshold;
        if (hidden[i] and inside(p.inner, x, y)) in_roi += 1;
    };
    const roi_fraction = @as(f32, @floatFromInt(in_roi)) / @as(f32, @floatFromInt(@as(usize, p.inner.w) * p.inner.h));
    try wmask.dilate(gpa, hidden, w, h, p.dilate);
    const accepted = roi_fraction >= p.min_fraction and roi_fraction <= p.max_fraction;
    // 見分けられなかった（何も無い / ほぼ全部）ときは、迷ったら広く隠す側: ROI の中はすべて隠す
    if (!accepted) for (p.inner.y..p.inner.y + p.inner.h) |y| @memset(hidden[y * w + p.inner.x ..][0..p.inner.w], true);

    var count: usize = 0;
    for (hidden) |hd| count += @intFromBool(hd);
    return .{
        .estimate = .{
            .hidden = hidden,
            .alpha = try wmask.alphaOf(gpa, hidden),
            .accepted = accepted,
            .fraction = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(n)),
            .threshold = p.threshold,
            .inside_mad = 0,
            .outside_mad = 0,
        },
        .roi_fraction = roi_fraction,
        .iterations = iterations,
    };
}

fn inside(r: Rect, x: usize, y: usize) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn median(v: []f32) f32 {
    std.mem.sort(f32, v, {}, std.sort.asc(f32));
    const m = v.len / 2;
    return if (v.len % 2 == 1) v[m] else (v[m - 1] + v[m]) / 2;
}

/// 勾配 (gx, gy) に最小二乗で最も近い像 u を求める（Neumann 境界のポアソン方程式、共役勾配法）。
/// gx[y*w+x] は u(x+1,y) - u(x,y)（x = w-1 は使わない）、gy は u(x,y+1) - u(x,y)（y = h-1 は使わない）。
/// u は定数の差を除いて決まるので、平均を 0 にする。反復回数を返す
fn poisson(gpa: std.mem.Allocator, gx: []const f32, gy: []const f32, w: u32, h: u32, u: []f32, max_iter: u32, tol: f32) !u32 {
    const n: usize = @as(usize, w) * h;
    // 正規方程式 A u = b。A は隣との差の和（グラフのラプラシアン、半正定値）、b = -div g
    const b = try gpa.alloc(f32, n);
    defer gpa.free(b);
    @memset(b, 0);
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        if (x + 1 < w) {
            b[i] -= gx[i];
            b[i + 1] += gx[i];
        }
        if (y + 1 < h) {
            b[i] -= gy[i];
            b[i + w] += gy[i];
        }
    };
    const r = try gpa.alloc(f32, n);
    defer gpa.free(r);
    const d = try gpa.alloc(f32, n);
    defer gpa.free(d);
    const ad = try gpa.alloc(f32, n);
    defer gpa.free(ad);
    @memset(u, 0);
    @memcpy(r, b);
    @memcpy(d, b);
    var rr: f64 = dot(r, r);
    const stop = @as(f64, tol) * @as(f64, tol) * @max(rr, 1e-12);
    var it: u32 = 0;
    while (it < max_iter and rr > stop) : (it += 1) {
        laplacian(d, w, h, ad);
        const dad = dot(d, ad);
        if (dad <= 0) break;
        const alpha: f32 = @floatCast(rr / dad);
        for (u, d) |*ui, di| ui.* += alpha * di;
        for (r, ad) |*ri, adi| ri.* -= alpha * adi;
        const rr_new = dot(r, r);
        const beta: f32 = @floatCast(rr_new / rr);
        for (d, r) |*di, ri| di.* = ri + beta * di.*;
        rr = rr_new;
    }
    var mean: f64 = 0;
    for (u) |v| mean += v;
    mean /= @floatFromInt(n);
    for (u) |*v| v.* -= @floatCast(mean);
    return it;
}

fn laplacian(v: []const f32, w: u32, h: u32, out: []f32) void {
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        var s: f32 = 0;
        if (x > 0) s += v[i] - v[i - 1];
        if (x + 1 < w) s += v[i] - v[i + 1];
        if (y > 0) s += v[i] - v[i - w];
        if (y + 1 < h) s += v[i] - v[i + w];
        out[i] = s;
    };
}

fn dot(a: []const f32, b: []const f32) f64 {
    var s: f64 = 0;
    for (a, b) |x, y| s += @as(f64, x) * y;
    return s;
}

// ---- tests -------------------------------------------------------------------

/// 背景は毎回乱数（80〜207）、(10..21, 6..11) に「口」の形（中が空いた枠、太さ 2）のウォーターマークを、
/// 不透明度 `opacity` で重ねた crop を n 枚。枠の中の空いた所は背景のまま
fn makeCrops(gpa: std.mem.Allocator, n: usize, w: u32, h: u32, opacity: f32) ![][]u8 {
    var prng: std.Random.DefaultPrng = .init(7);
    const crops = try gpa.alloc([]u8, n);
    for (crops) |*cr| {
        cr.* = try gpa.alloc(u8, @as(usize, w) * h * 3);
        prng.random().bytes(cr.*);
        for (cr.*) |*v| v.* = 80 + v.* / 2;
        for (6..12) |y| for (10..22) |x| {
            if (!inFrame(x, y)) continue;
            const px = cr.*[(y * w + x) * 3 ..][0..3];
            const wm = [3]f32{ 250, 240, 20 };
            for (px, wm) |*v, t| v.* = @intFromFloat(@round(opacity * t + (1 - opacity) * @as(f32, @floatFromInt(v.*))));
        };
    }
    return crops;
}

fn inFrame(x: usize, y: usize) bool {
    return x < 12 or x >= 20 or y < 8 or y >= 10;
}

fn freeCrops(gpa: std.mem.Allocator, crops: [][]u8) void {
    for (crops) |c| gpa.free(c);
    gpa.free(crops);
}

test "wgrad: poisson integrates a gradient field back to the image (up to a constant)" {
    const gpa = std.testing.allocator;
    const w = 9;
    const h = 7;
    var img: [w * h]f32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        img[y * w + x] = @as(f32, @floatFromInt(x * x)) - 3 * @as(f32, @floatFromInt(y)) + if (x > 3 and y > 2) @as(f32, 40) else 0;
    };
    var gx = [_]f32{0} ** (w * h);
    var gy = [_]f32{0} ** (w * h);
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        if (x + 1 < w) gx[i] = img[i + 1] - img[i];
        if (y + 1 < h) gy[i] = img[i + w] - img[i];
    };
    var u: [w * h]f32 = undefined;
    _ = try poisson(gpa, &gx, &gy, w, h, &u, 2000, 1e-6);
    const off = img[0] - u[0];
    for (img, u) |a, b| try std.testing.expectApproxEqAbs(a, b + off, 1e-2);
}

test "wgrad: finds the watermark's shape, including the inside of the strokes, but not the background inside the frame" {
    const gpa = std.testing.allocator;
    const w = 32;
    const h = 18;
    const inner: Rect = .{ .x = 6, .y = 3, .w = 20, .h = 12 };
    for ([_]f32{ 1, 0.5 }) |opacity| {
        const crops = try makeCrops(gpa, 151, w, h, opacity);
        defer freeCrops(gpa, crops);
        const r = try estimate(gpa, crops, w, h, .{ .inner = inner, .dilate = 0 });
        defer r.estimate.deinit(gpa);
        try std.testing.expect(r.estimate.accepted);
        for (0..h) |y| for (0..w) |x| {
            const wm = y >= 6 and y < 12 and x >= 10 and x < 22 and inFrame(x, y);
            try std.testing.expectEqual(wm, r.estimate.hidden[y * w + x]);
        };
        // 1 px 広げると周り 1 px も隠す（枠の中の空いた所 2 x 2 も、四方が 1 px 以内なので埋まる）
        const r1 = try estimate(gpa, crops, w, h, .{ .inner = inner });
        defer r1.estimate.deinit(gpa);
        try std.testing.expect(r1.estimate.hidden[5 * w + 9]); // 左上の斜め隣
        try std.testing.expect(!r1.estimate.hidden[4 * w + 9]); // 2 px 離れた所は隠さない
        try std.testing.expectEqual(@as(u8, 255), r1.estimate.alpha[5 * w + 9]);
    }
}

test "wgrad: when nothing stands out, it hides the whole ROI instead of nothing" {
    const gpa = std.testing.allocator;
    const w = 32;
    const h = 18;
    const inner: Rect = .{ .x = 6, .y = 3, .w = 20, .h = 12 };
    // 不透明度 0 = ウォーターマークが無い
    const crops = try makeCrops(gpa, 151, w, h, 0);
    defer freeCrops(gpa, crops);
    const r = try estimate(gpa, crops, w, h, .{ .inner = inner });
    defer r.estimate.deinit(gpa);
    try std.testing.expect(!r.estimate.accepted);
    try std.testing.expect(r.estimate.hidden[inner.y * w + inner.x]);
    try std.testing.expect(!r.estimate.hidden[0]);
}
