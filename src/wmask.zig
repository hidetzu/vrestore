//! ROI の中で、ウォーターマークの画素（文字や縁取り）だけを見分ける。
//!
//! ウォーターマークは動画のどのフレームでも同じ位置・同じ色で、背景はフレームごとに変わる。動画全体から取った
//! フレームで画素ごとの「色の変わりやすさ」（中央値からの差の中央値、R/G/B の大きい方）を出し、
//! 変わりにくい画素をウォーターマークとする。閾値は大津の二値化で ROI ごとに決める。
//!
//! 半透明のウォーターマークは背景と一緒に色が変わるので、変わりやすさだけでは見落とす。ウォーターマークの縁は
//! どのフレームでも同じ向きの明るさの変化（勾配）を持ち、背景の縁は時間で打ち消し合うので、
//! 勾配の時間方向の中央値が大きい画素も縁として加える（Dekel et al. 2017 と同じ手がかり）。
//!
//! ⚠ 見落とした画素は「隠れていない」と扱われ、ウォーターマークがそのまま残る。迷ったら広く隠す側に倒す:
//! - 縁のにじみを含めるため、見分けた画素を `dilate` px 広げる
//! - ウォーターマークと背景の変わりやすさが分かれていない（背景も動かない等）ときは、マスクを使わず ROI 全体を隠す
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Params = struct {
    /// 推定する範囲（crop）の中の ROI。見分けられなかったとき、ROI の中はすべて隠し、ROI の外（周りの帯）は
    /// どのフレームでも同じ縁（ROI からはみ出したウォーターマーク）だけを隠す。null なら範囲全体を隠す
    inner: ?Rect = null,
    /// 見分けた画素を広げる幅（px）。ウォーターマークの縁取りの外側の圧縮のにじみまで隠す（ADR 0011）
    dilate: u32 = 2,
    /// 勾配の時間方向の中央値の大きさが、背景（変わりにくくない画素）の中央値の何倍を超えたら縁とみなすか。0 なら縁を使わない
    edge_ratio: f32 = 5,
    /// 縁とみなす大きさの下限（8 bit の明るさ / px）。背景が平らで中央値が 0 に近いときに、圧縮の雑音を拾わない
    min_edge: f32 = 8,
    /// 背景の変わりやすさ（中央値）が、ウォーターマークの何倍以上なら見分けられたとみなすか
    min_separation: f32 = 1.5,
    /// 背景の変わりやすさの下限。これ未満なら背景もほぼ動いていない（固定カメラ）とみなす
    min_background_mad: f32 = 8,
    /// 変わりにくいとした画素の割合（縁を足す前・広げる前）がこの範囲の外なら、見分けられていないとみなす
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

    // 閾値の内側と外側の変わりやすさ（広げる前、縁を足す前の判定で測る）
    const inside_mad, const outside_mad = try splitMedians(gpa, mad, hidden);
    const still_fraction = fractionOf(hidden);

    const edge_map: ?[]bool = if (p.edge_ratio > 0) try edges(gpa, crops, w, h, hidden, p.edge_ratio, p.min_edge) else null;
    defer if (edge_map) |em| gpa.free(em);
    // 縁は広げない: 中心差分は両隣を見るので、縁はウォーターマークの外側 1 px まで既に付いている
    if (edge_map) |em| for (hidden, em) |*hd, e| {
        hd.* = hd.* or e;
    };

    try dilate(gpa, hidden, w, h, p.dilate);

    const accepted = outside_mad >= p.min_background_mad and
        outside_mad >= p.min_separation * inside_mad and
        still_fraction >= p.min_fraction and still_fraction <= p.max_fraction;
    if (!accepted) {
        if (p.inner) |r| {
            // 背景も動かず変わりにくさでは見分けられない。ROI の中はすべて隠し、周りの帯は縁だけを広げて隠す
            // （手で選んだ ROI からはみ出した文字の端が残り、それを手がかりに埋めて周りへにじんだ）
            // 縁の閾値は範囲全体の中央値から取り直す。背景が止まっていると「変わりにくくない画素」はむしろ文字の方で、
            // それを基準にすると閾値が高すぎて、はみ出した文字の縁を拾えなかった（フェードの 30 秒で観測）
            @memset(hidden, false);
            if (p.edge_ratio > 0) {
                const em = try edges(gpa, crops, w, h, null, p.edge_ratio, p.min_edge);
                defer gpa.free(em);
                @memcpy(hidden, em);
                try dilate(gpa, hidden, w, h, p.dilate);
            }
            for (r.y..r.y + r.h) |y| @memset(hidden[y * w + r.x ..][0..r.w], true);
        } else @memset(hidden, true);
    }
    return .{
        .hidden = hidden,
        .accepted = accepted,
        .fraction = fractionOf(hidden),
        .threshold = th,
        .inside_mad = inside_mad,
        .outside_mad = outside_mad,
    };
}

fn fractionOf(m: []const bool) f32 {
    var cnt: usize = 0;
    for (m) |b| cnt += @intFromBool(b);
    return @as(f32, @floatFromInt(cnt)) / @as(f32, @floatFromInt(m.len));
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

/// 勾配（明るさ = R/G/B の平均の中心差分）の時間方向の中央値の大きさが、しきい値を超える画素。
/// しきい値は `still`（変わりにくい画素）の外の中央値から決める。ROI 全体の中央値にすると、ROI のうちウォーターマークが
/// 占める割合（= 指定した範囲の広さ）でしきい値が大きく動く
/// `still` が null なら、範囲の全画素の中央値から決める（変わりやすさで背景を見分けられなかったとき）
fn edges(gpa: std.mem.Allocator, crops: []const []const u8, w: u32, h: u32, still: ?[]const bool, ratio: f32, min_edge: f32) ![]bool {
    const n: usize = @as(usize, w) * h;
    const mag = try gpa.alloc(f32, n);
    defer gpa.free(mag);
    const gx = try gpa.alloc(f32, crops.len);
    defer gpa.free(gx);
    const gy = try gpa.alloc(f32, crops.len);
    defer gpa.free(gy);
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        if (x == 0 or y == 0 or x + 1 == w or y + 1 == h) {
            mag[i] = 0;
            continue;
        }
        for (crops, gx, gy) |cr, *ax, *ay| {
            ax.* = (luma(cr, i + 1) - luma(cr, i - 1)) / 2;
            ay.* = (luma(cr, i + w) - luma(cr, i - w)) / 2;
        }
        mag[i] = std.math.hypot(median(gx), median(gy));
    };
    var bg: std.ArrayList(f32) = .empty;
    defer bg.deinit(gpa);
    if (still) |st| {
        for (mag, st) |m, s| if (!s) try bg.append(gpa, m);
    } else try bg.appendSlice(gpa, mag);
    const th = @max(min_edge, if (bg.items.len > 0) ratio * median(bg.items) else min_edge);
    const out = try gpa.alloc(bool, n);
    for (mag, out) |m, *o| o.* = m > th;
    return out;
}

fn luma(cr: []const u8, i: usize) f32 {
    const px = cr[i * 3 ..][0..3];
    return (@as(f32, @floatFromInt(px[0])) + @as(f32, @floatFromInt(px[1])) + @as(f32, @floatFromInt(px[2]))) / 3;
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
    const e = try estimate(gpa, crops, w, h, .{ .dilate = 0, .edge_ratio = 0 });
    defer e.deinit(gpa);
    try std.testing.expect(e.accepted);
    for (0..h) |y| for (0..w) |x| {
        const wm = y >= 3 and y < 6 and x >= 4 and x < 11;
        try std.testing.expectEqual(wm, e.hidden[y * w + x]);
    };

    // 1 px 広げると、ウォーターマークの周り 1 px も隠す
    const e1 = try estimate(gpa, crops, w, h, .{ .dilate = 1, .edge_ratio = 0 });
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

/// 背景は平らで、左半分は明るさがフレームごとに大きく変わり、右半分はほぼ変わらない（どちらも ±2 の雑音）。
/// そこに不透明度 30% の白い細い棒 (6..26, 5..8) を重ねた crop を n 枚。
/// 左半分の棒は背景と一緒に色が変わるので、変わりやすさだけでは背景と見分けにくい
fn makeTranslucentCrops(gpa: std.mem.Allocator, n: usize, w: u32, h: u32) ![][]u8 {
    var prng: std.Random.DefaultPrng = .init(9);
    const r = prng.random();
    const crops = try gpa.alloc([]u8, n);
    for (crops) |*cr| {
        cr.* = try gpa.alloc(u8, @as(usize, w) * h * 3);
        const left = r.intRangeAtMost(i32, 8, 248);
        const right = 128 + r.intRangeAtMost(i32, -3, 3);
        for (0..h) |y| for (0..w) |x| {
            var v: f32 = @floatFromInt((if (x < w / 2) left else right) + r.intRangeAtMost(i32, -2, 2));
            if (x >= 6 and x < 26 and y >= 5 and y < 8) v = 0.7 * v + 0.3 * 250;
            @memset(cr.*[(y * w + x) * 3 ..][0..3], @intFromFloat(@round(v)));
        };
    }
    return crops;
}

test "wmask: the edges catch a translucent watermark that the stillness alone misses" {
    const gpa = std.testing.allocator;
    const w = 32;
    const h = 14;
    const crops = try makeTranslucentCrops(gpa, 31, w, h);
    defer {
        for (crops) |c| gpa.free(c);
        gpa.free(crops);
    }
    const recall = struct {
        fn f(e: Estimate) f32 {
            var tp: u32 = 0;
            for (5..8) |y| for (6..26) |x| {
                tp += @intFromBool(e.hidden[y * w + x]);
            };
            return @as(f32, @floatFromInt(tp)) / (20 * 3);
        }
    }.f;
    const still = try estimate(gpa, crops, w, h, .{ .edge_ratio = 0 });
    defer still.deinit(gpa);
    const both = try estimate(gpa, crops, w, h, .{});
    defer both.deinit(gpa);
    try std.testing.expect(both.accepted);
    try std.testing.expect(recall(still) < 0.9);
    try std.testing.expectEqual(@as(f32, 1), recall(both));
}

test "wmask: whether the mask is used is judged before the edges and the dilation widen it" {
    // 40 x 20 の上 18 行（90%）が動かないウォーターマーク、下 2 行が毎回乱数の背景。
    // 縁と広げた分で隠す割合は 100% になるが、変わりにくい画素は 90% なので見分けられている
    const gpa = std.testing.allocator;
    const w = 40;
    const h = 20;
    var prng: std.Random.DefaultPrng = .init(3);
    const crops = try gpa.alloc([]u8, 21);
    defer gpa.free(crops);
    for (crops) |*cr| {
        cr.* = try gpa.alloc(u8, w * h * 3);
        prng.random().bytes(cr.*);
        @memset(cr.*[0 .. w * 18 * 3], 250);
    }
    defer for (crops) |c| gpa.free(c);
    const e = try estimate(gpa, crops, w, h, .{});
    defer e.deinit(gpa);
    try std.testing.expect(e.accepted);
    try std.testing.expectEqual(@as(f32, 1), e.fraction);
}

test "wmask: when it cannot tell, it hides the ROI and only the watermark's edges sticking out of it" {
    // 背景は白で張り付いて動かない（フェードでも 255 のまま）。ウォーターマーク (4..11, 3..6) だけがフェードで明るさを変え、
    // ROI (6..14, 2..8) から左に 2 px はみ出している。変わりやすさでは見分けられず、「変わりにくくない画素」はむしろ文字の方
    const gpa = std.testing.allocator;
    const w = 20;
    const h = 10;
    const crops = try gpa.alloc([]u8, 21);
    defer gpa.free(crops);
    for (crops, 0..) |*cr, k| {
        cr.* = try gpa.alloc(u8, w * h * 3);
        @memset(cr.*, 255);
        const level: u8 = @intCast(120 + k % 5); // 変わり方は小さい（変わりやすさの下限 8 未満）
        for (3..6) |y| for (4..11) |x| {
            cr.*[(y * w + x) * 3 ..][0..3].* = .{ level, level, 0 };
        };
    }
    defer for (crops) |c| gpa.free(c);
    const e = try estimate(gpa, crops, w, h, .{ .inner = .{ .x = 6, .y = 2, .w = 8, .h = 6 }, .dilate = 1 });
    defer e.deinit(gpa);
    try std.testing.expect(!e.accepted);
    // ROI の中はすべて隠す
    for (2..8) |y| for (6..14) |x| try std.testing.expect(e.hidden[y * w + x]);
    // ROI の外にはみ出した文字（x = 4, 5）は隠す
    for (3..6) |y| for (4..6) |x| try std.testing.expect(e.hidden[y * w + x]);
    // 文字から離れた背景は隠さない
    try std.testing.expect(!e.hidden[9 * w + 0]);
    try std.testing.expect(!e.hidden[0 * w + 18]);
    try std.testing.expect(e.fraction < 1);
}

test "wmask: otsu splits two clusters" {
    var v = [_]f32{ 1, 2, 1, 3, 2, 40, 42, 41, 39, 45 };
    const th = otsu(&v);
    try std.testing.expect(th > 3 and th < 39);
}
