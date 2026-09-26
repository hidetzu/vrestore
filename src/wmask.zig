//! ROI の中で、ウォーターマークの画素（文字や縁取り）だけを見分ける。
//!
//! ウォーターマークは動画のどのフレームでも同じ位置・同じ色で、背景はフレームごとに変わる。動画全体から取った
//! フレームで画素ごとの「色の変わりやすさ」（中央値からの差の中央値、R/G/B の大きい方）を出し、
//! 変わりにくい画素をウォーターマークとする。閾値は大津の二値化で ROI ごとに決める。
//!
//! ⚠ 見落とした画素は「隠れていない」と扱われ、ウォーターマークがそのまま残る。迷ったら広く隠す側に倒す:
//! - 縁のにじみを含めるため、見分けた画素を `dilate` px 広げる
//! - ウォーターマークと背景の変わりやすさが分かれていない（背景も動かない等）ときは、マスクを使わず ROI 全体を隠す
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");

pub const Params = struct {
    /// 見分けた画素を広げる幅（px）
    dilate: u32 = 1,
    /// 背景の変わりやすさ（中央値）が、ウォーターマークの何倍以上なら見分けられたとみなすか
    min_separation: f32 = 1.5,
    /// 背景の変わりやすさの下限。これ未満なら背景もほぼ動いていない（固定カメラ）とみなす
    min_background_mad: f32 = 8,
    /// 隠す画素の割合がこの範囲の外なら、見分けられていないとみなす
    min_fraction: f32 = 0.02,
    max_fraction: f32 = 0.95,
};

pub const Estimate = struct {
    /// ROI の画素ごと（行優先、w x h）。true = ウォーターマーク（隠れている）
    hidden: []bool,
    /// マスクを使うか。false なら見分けられなかったので ROI 全体を隠す（`hidden` はすべて true）
    accepted: bool,
    /// 隠す画素の割合（広げた後）
    fraction: f32,
    /// 大津の閾値と、閾値の内側 / 外側の変わりやすさの中央値
    threshold: f32,
    inside_mad: f32,
    outside_mad: f32,

    pub fn deinit(e: Estimate, gpa: std.mem.Allocator) void {
        gpa.free(e.hidden);
    }
};

/// `crops` は同じ ROI（w x h、RGB24）を別々のフレームから切り出したもの。3 枚以上
pub fn estimate(gpa: std.mem.Allocator, crops: []const []const u8, w: u32, h: u32, p: Params) !Estimate {
    std.debug.assert(crops.len >= 3);
    const n: usize = @as(usize, w) * h;
    const mad = try gpa.alloc(f32, n);
    defer gpa.free(mad);
    const col = try gpa.alloc(f32, crops.len);
    defer gpa.free(col);
    const dev = try gpa.alloc(f32, crops.len);
    defer gpa.free(dev);
    for (0..n) |i| {
        var worst: f32 = 0;
        for (0..3) |c| {
            for (crops, col) |cr, *v| v.* = @floatFromInt(cr[i * 3 + c]);
            const med = median(col);
            for (col, dev) |v, *d| d.* = @abs(v - med);
            worst = @max(worst, median(dev));
        }
        mad[i] = worst;
    }

    const th = otsu(mad);
    const hidden = try gpa.alloc(bool, n);
    errdefer gpa.free(hidden);
    for (mad, hidden) |v, *hd| hd.* = v < th;

    // 閾値の内側と外側の変わりやすさ（広げる前の判定で測る）
    const inside_mad, const outside_mad = try splitMedians(gpa, mad, hidden);

    try dilate(gpa, hidden, w, h, p.dilate);
    var cnt: usize = 0;
    for (hidden) |hd| cnt += @intFromBool(hd);
    const fraction = @as(f32, @floatFromInt(cnt)) / @as(f32, @floatFromInt(n));

    const accepted = outside_mad >= p.min_background_mad and
        outside_mad >= p.min_separation * inside_mad and
        fraction >= p.min_fraction and fraction <= p.max_fraction;
    if (!accepted) @memset(hidden, true);
    return .{
        .hidden = hidden,
        .accepted = accepted,
        .fraction = if (accepted) fraction else 1,
        .threshold = th,
        .inside_mad = inside_mad,
        .outside_mad = outside_mad,
    };
}

/// その場で並べ替えて中央値を返す
fn median(v: []f32) f32 {
    std.mem.sort(f32, v, {}, std.sort.asc(f32));
    const m = v.len / 2;
    return if (v.len % 2 == 1) v[m] else (v[m - 1] + v[m]) / 2;
}

/// 大津の二値化: 2 つに分けたときのクラス間分散が最大になる閾値（128 段のヒストグラム）
fn otsu(v: []const f32) f32 {
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (v) |x| {
        lo = @min(lo, x);
        hi = @max(hi, x);
    }
    if (hi <= lo) return hi + 1;
    const bins = 128;
    var hist = [_]f64{0} ** bins;
    const scale = @as(f32, bins) / (hi - lo);
    for (v) |x| hist[@min(bins - 1, @as(usize, @intFromFloat((x - lo) * scale)))] += 1;
    var total: f64 = 0;
    var sum: f64 = 0;
    for (hist, 0..) |c, i| {
        total += c;
        sum += c * @as(f64, @floatFromInt(i));
    }
    var w0: f64 = 0;
    var s0: f64 = 0;
    var best: f64 = -1;
    var best_i: usize = 1;
    for (0..bins - 1) |i| {
        w0 += hist[i];
        s0 += hist[i] * @as(f64, @floatFromInt(i));
        const w1 = total - w0;
        if (w0 == 0 or w1 == 0) continue;
        const m0 = s0 / w0;
        const m1 = (sum - s0) / w1;
        const between = w0 * w1 * (m0 - m1) * (m0 - m1);
        if (between > best) {
            best = between;
            best_i = i + 1;
        }
    }
    return lo + @as(f32, @floatFromInt(best_i)) / scale;
}

fn splitMedians(gpa: std.mem.Allocator, mad: []const f32, hidden: []const bool) !struct { f32, f32 } {
    var a: std.ArrayList(f32) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(f32) = .empty;
    defer b.deinit(gpa);
    for (mad, hidden) |v, hd| try (if (hd) &a else &b).append(gpa, v);
    return .{ if (a.items.len > 0) median(a.items) else 0, if (b.items.len > 0) median(b.items) else 0 };
}

/// true の画素を上下左右斜めに `r` px 広げる
fn dilate(gpa: std.mem.Allocator, m: []bool, w: u32, h: u32, r: u32) !void {
    if (r == 0) return;
    const src = try gpa.dupe(bool, m);
    defer gpa.free(src);
    const ri: i64 = r;
    for (0..h) |y| for (0..w) |x| {
        if (src[y * w + x]) continue;
        var any = false;
        var dy: i64 = -ri;
        while (dy <= ri and !any) : (dy += 1) {
            var dx: i64 = -ri;
            while (dx <= ri) : (dx += 1) {
                const nx = @as(i64, @intCast(x)) + dx;
                const ny = @as(i64, @intCast(y)) + dy;
                if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                if (src[@as(usize, @intCast(ny)) * w + @as(usize, @intCast(nx))]) {
                    any = true;
                    break;
                }
            }
        }
        m[y * w + x] = any;
    };
}

// ---- tests -------------------------------------------------------------------

/// 背景は毎回乱数、(4..11, 3..6) だけ同じ色（ウォーターマーク）の crop を n 枚
fn makeCrops(gpa: std.mem.Allocator, n: usize, w: u32, h: u32, moving: bool) ![][]u8 {
    var prng: std.Random.DefaultPrng = .init(5);
    const crops = try gpa.alloc([]u8, n);
    const still = try gpa.alloc(u8, @as(usize, w) * h * 3);
    defer gpa.free(still);
    prng.random().bytes(still);
    for (crops) |*cr| {
        cr.* = try gpa.alloc(u8, @as(usize, w) * h * 3);
        if (moving) prng.random().bytes(cr.*) else @memcpy(cr.*, still);
        for (3..6) |y| for (4..11) |x| {
            cr.*[(y * w + x) * 3 ..][0..3].* = .{ 250, 240, 20 };
        };
    }
    return crops;
}

test "wmask: finds the pixels that stay the same while the background changes" {
    const gpa = std.testing.allocator;
    const w = 16;
    const h = 10;
    const crops = try makeCrops(gpa, 21, w, h, true);
    defer {
        for (crops) |c| gpa.free(c);
        gpa.free(crops);
    }
    const e = try estimate(gpa, crops, w, h, .{ .dilate = 0 });
    defer e.deinit(gpa);
    try std.testing.expect(e.accepted);
    for (0..h) |y| for (0..w) |x| {
        const wm = y >= 3 and y < 6 and x >= 4 and x < 11;
        try std.testing.expectEqual(wm, e.hidden[y * w + x]);
    };

    // 1 px 広げると、ウォーターマークの周り 1 px も隠す
    const e1 = try estimate(gpa, crops, w, h, .{ .dilate = 1 });
    defer e1.deinit(gpa);
    try std.testing.expect(e1.hidden[2 * w + 3]); // 左上の斜め隣
    try std.testing.expect(!e1.hidden[1 * w + 3]); // 2 px 離れた所は隠さない
}

test "wmask: falls back to hiding the whole ROI when the background does not move either" {
    const gpa = std.testing.allocator;
    const crops = try makeCrops(gpa, 21, 16, 10, false);
    defer {
        for (crops) |c| gpa.free(c);
        gpa.free(crops);
    }
    const e = try estimate(gpa, crops, 16, 10, .{});
    defer e.deinit(gpa);
    try std.testing.expect(!e.accepted);
    try std.testing.expectEqual(@as(f32, 1), e.fraction);
    for (e.hidden) |hd| try std.testing.expect(hd);
}

test "wmask: otsu splits two clusters" {
    var v = [_]f32{ 1, 2, 1, 3, 2, 40, 42, 41, 39, 45 };
    const th = otsu(&v);
    try std.testing.expect(th > 3 and th < 39);
}
