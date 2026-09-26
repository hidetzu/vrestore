//! ROI 検出: 利用者が切り出したウォーターマーク参照画像が、動画内のどこに固定されているかを探す。
//!
//! 解く問題は「どれがウォーターマークか」ではなく「指定されたものがどこにあるか」(docs/SPEC.md §2-1)。
//! 背景復元とは分けてある (docs/adr/0002)。この module は FFmpeg に依存しない。
//!
//! 1 フレームずつ gradient ZNCC で最良位置を探し、複数フレームの最頻位置を ROI とする。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// RGB24 で詰めた画像。video.Frame と同じ並び
pub const Image = struct {
    width: u32,
    height: u32,
    rgb: []const u8,
};

/// 1 チャンネルの浮動小数画像。輝度や勾配の大きさを入れる。
pub const Plane = struct {
    w: usize,
    h: usize,
    px: []f32,

    pub fn init(gpa: Allocator, w: usize, h: usize) Allocator.Error!Plane {
        return .{ .w = w, .h = h, .px = try gpa.alloc(f32, w * h) };
    }

    pub fn deinit(p: Plane, gpa: Allocator) void {
        gpa.free(p.px);
    }

    inline fn at(p: Plane, x: usize, y: usize) f32 {
        return p.px[y * p.w + x];
    }
};

/// RGB を輝度 (BT.601 の係数) に落とす。
pub fn grayscale(gpa: Allocator, img: Image) Allocator.Error!Plane {
    const p = try Plane.init(gpa, img.width, img.height);
    for (p.px, 0..) |*v, i| {
        const r: f32 = @floatFromInt(img.rgb[i * 3]);
        const g: f32 = @floatFromInt(img.rgb[i * 3 + 1]);
        const b: f32 = @floatFromInt(img.rgb[i * 3 + 2]);
        v.* = 0.299 * r + 0.587 * g + 0.114 * b;
    }
    return p;
}

/// 勾配の大きさ（中心差分、端は片側差分）。
///
/// 輝度そのままで照合すると、参照画像に写り込んだ背景に引きずられる。勾配なら輪郭だけを見るので、
/// 背景が違うフレームから切った参照画像でも当たる（PoC、mp4tool）。
pub fn gradient(gpa: Allocator, p: Plane) Allocator.Error!Plane {
    std.debug.assert(p.w >= 2 and p.h >= 2);
    const g = try Plane.init(gpa, p.w, p.h);
    for (0..p.h) |y| {
        for (0..p.w) |x| {
            const dx: f32 = if (x == 0)
                p.at(1, y) - p.at(0, y)
            else if (x == p.w - 1)
                p.at(x, y) - p.at(x - 1, y)
            else
                (p.at(x + 1, y) - p.at(x - 1, y)) / 2;
            const dy: f32 = if (y == 0)
                p.at(x, 1) - p.at(x, 0)
            else if (y == p.h - 1)
                p.at(x, y) - p.at(x, y - 1)
            else
                (p.at(x, y + 1) - p.at(x, y - 1)) / 2;
            g.px[y * p.w + x] = @sqrt(dx * dx + dy * dy);
        }
    }
    return g;
}

/// 2x2 平均で半分に縮める。端数の行・列は捨てる。
fn downsample(gpa: Allocator, p: Plane) Allocator.Error!Plane {
    const d = try Plane.init(gpa, p.w / 2, p.h / 2);
    for (0..d.h) |y| {
        for (0..d.w) |x| {
            const s = p.at(2 * x, 2 * y) + p.at(2 * x + 1, 2 * y) + p.at(2 * x, 2 * y + 1) + p.at(2 * x + 1, 2 * y + 1);
            d.px[y * d.w + x] = s / 4;
        }
    }
    return d;
}

/// 積分画像と二乗の積分画像。ZNCC の分母を窓ごとに O(1) で出すため。
/// 大きな画像で f32 だと桁が落ちるので f64 で持つ。
const Integrals = struct {
    w: usize,
    sum: []f64,
    sqr: []f64,

    fn init(gpa: Allocator, p: Plane) Allocator.Error!Integrals {
        const iw = p.w + 1;
        const n = iw * (p.h + 1);
        const sum = try gpa.alloc(f64, n);
        errdefer gpa.free(sum);
        const sqr = try gpa.alloc(f64, n);
        @memset(sum, 0);
        @memset(sqr, 0);
        for (0..p.h) |y| {
            var rs: f64 = 0;
            var rq: f64 = 0;
            for (0..p.w) |x| {
                const v: f64 = p.at(x, y);
                rs += v;
                rq += v * v;
                sum[(y + 1) * iw + x + 1] = sum[y * iw + x + 1] + rs;
                sqr[(y + 1) * iw + x + 1] = sqr[y * iw + x + 1] + rq;
            }
        }
        return .{ .w = iw, .sum = sum, .sqr = sqr };
    }

    fn deinit(it: Integrals, gpa: Allocator) void {
        gpa.free(it.sum);
        gpa.free(it.sqr);
    }

    /// 左上 (x,y)、w x h の矩形の和と二乗和
    fn rect(it: Integrals, x: usize, y: usize, w: usize, h: usize) [2]f64 {
        const a = y * it.w + x;
        const b = y * it.w + x + w;
        const c = (y + h) * it.w + x;
        const d = (y + h) * it.w + x + w;
        return .{ it.sum[d] - it.sum[b] - it.sum[c] + it.sum[a], it.sqr[d] - it.sqr[b] - it.sqr[c] + it.sqr[a] };
    }
};

/// 照合するひな型。平均を引いた値と、その二乗和を持つ。
const Template = struct {
    w: usize,
    h: usize,
    zs: []f32,
    ss: f64,

    fn init(gpa: Allocator, p: Plane) Allocator.Error!Template {
        var mean: f64 = 0;
        for (p.px) |v| mean += v;
        mean /= @floatFromInt(p.px.len);
        const zs = try gpa.alloc(f32, p.px.len);
        var ss: f64 = 0;
        for (p.px, zs) |v, *z| {
            z.* = @floatCast(v - mean);
            ss += @as(f64, z.*) * z.*;
        }
        return .{ .w = p.w, .h = p.h, .zs = zs, .ss = ss };
    }

    fn deinit(t: Template, gpa: Allocator) void {
        gpa.free(t.zs);
    }
};

/// 窓の左上を (x,y) としたときの正規化相互相関。どちらかが平坦なら 0。
fn zncc(img: Plane, it: Integrals, t: Template, x: usize, y: usize) f64 {
    if (t.ss <= 0) return 0;
    const sq = it.rect(x, y, t.w, t.h);
    const n: f64 = @floatFromInt(t.w * t.h);
    const variance = sq[1] - sq[0] * sq[0] / n;
    if (variance <= 1e-9) return 0;
    // テンプレート側は平均 0 なので、画像側の平均は引かなくても分子は同じ
    var num: f64 = 0;
    for (0..t.h) |j| {
        const row = img.px[(y + j) * img.w + x ..][0..t.w];
        const zrow = t.zs[j * t.w ..][0..t.w];
        var acc: f32 = 0;
        for (row, zrow) |a, b| acc += a * b;
        num += acc;
    }
    return num / @sqrt(variance * t.ss);
}

/// 1 フレームに対する照合結果。
pub const Match = struct {
    x: usize,
    y: usize,
    /// 最良位置の ZNCC。[-1, 1]
    peak: f64,
    /// ピークの突出度: ピーク近傍を除いた分布の平均から、標準偏差いくつ分離れているか。
    /// 探索した階層の解像度で絶対値が動く。比べる相手が無い・分布が平らなときは null
    psr: ?f64,
    /// ピークと、ピーク近傍を除いた最良値との差。ZNCC の差なので解像度によらず比べられる。
    /// 比べる相手の位置が無い（参照画像が動画とほぼ同じ大きさ）ときは null
    margin: ?f64,
};

pub const LocateError = error{
    TemplateLargerThanImage,
    TemplateTooSmall,
    /// 参照画像に輪郭が無い（勾配がすべて 0）。どこと比べても相関が定義できない
    FlatTemplate,
} || Allocator.Error;

/// ひな型の最小辺。これ未満では勾配の特徴が足りず、粗い階層で当たらない
pub const min_template_side = 12;

/// `img` の中から `tmpl` を探す。
///
/// 粗い階層で全探索して大域の最良位置と PSR / margin を出し、細かい階層へ降りながら
/// 周囲 ±refine だけ見直す。全解像度での全探索を避ける。
pub fn locate(gpa: Allocator, img: Plane, tmpl: Plane) LocateError!Match {
    if (tmpl.w > img.w or tmpl.h > img.h) return error.TemplateLargerThanImage;
    if (tmpl.w < min_template_side or tmpl.h < min_template_side) return error.TemplateTooSmall;
    if (std.mem.allEqual(f32, tmpl.px, tmpl.px[0])) return error.FlatTemplate;
    const refine = 3;

    const levels = pyramidLevels(img.w, img.h, tmpl.w, tmpl.h);
    var imgs: [max_levels + 1]Plane = undefined;
    var tmps: [max_levels + 1]Plane = undefined;
    imgs[0] = img;
    tmps[0] = tmpl;
    var built: usize = 0;
    defer for (1..built + 1) |i| {
        imgs[i].deinit(gpa);
        tmps[i].deinit(gpa);
    };
    for (0..levels) |i| {
        imgs[i + 1] = try downsample(gpa, imgs[i]);
        tmps[i + 1] = downsample(gpa, tmps[i]) catch |e| {
            imgs[i + 1].deinit(gpa);
            return e;
        };
        built += 1;
    }

    var res = try searchFull(gpa, imgs[levels], tmps[levels]);
    var l = levels;
    while (l > 0) {
        l -= 1;
        const r = try searchWindow(gpa, imgs[l], tmps[l], res.x * 2, res.y * 2, refine);
        res.x = r.x;
        res.y = r.y;
        res.peak = r.peak;
    }
    return res;
}

const max_levels = 4;

/// ひな型が min_template_side を下回らない範囲で何段まで縮められるか。
fn pyramidLevels(img_w: usize, img_h: usize, tw: usize, th: usize) usize {
    var iw = img_w;
    var ih = img_h;
    var w = tw;
    var h = th;
    var n: usize = 0;
    while (n < max_levels) : (n += 1) {
        if (w / 2 < min_template_side or h / 2 < min_template_side or iw / 2 < w or ih / 2 < h) break;
        iw /= 2;
        ih /= 2;
        w /= 2;
        h /= 2;
    }
    return n;
}

fn searchFull(gpa: Allocator, img: Plane, tmpl: Plane) Allocator.Error!Match {
    const it = try Integrals.init(gpa, img);
    defer it.deinit(gpa);
    const t = try Template.init(gpa, tmpl);
    defer t.deinit(gpa);
    const mw = img.w - t.w + 1;
    const mh = img.h - t.h + 1;
    const scores = try gpa.alloc(f64, mw * mh);
    defer gpa.free(scores);

    var best: Match = .{ .x = 0, .y = 0, .peak = -std.math.inf(f64), .psr = null, .margin = null };
    for (0..mh) |y| {
        for (0..mw) |x| {
            const v = zncc(img, it, t, x, y);
            scores[y * mw + x] = v;
            if (v > best.peak) {
                best.x = x;
                best.y = y;
                best.peak = v;
            }
        }
    }
    const s = peakStats(scores, mw, mh, best.x, best.y);
    best.psr = s.psr;
    best.margin = s.margin;
    return best;
}

/// ピーク近傍 (±8) を除いた分布から、PSR と 2 番手との差を出す。
/// 近傍を除く点が 2 つ未満（探索範囲がほぼひな型と同じ大きさ）のときはどちらも null。
fn peakStats(scores: []const f64, w: usize, h: usize, px: usize, py: usize) struct { psr: ?f64, margin: ?f64 } {
    const excl = 8;
    var n: usize = 0;
    var mean: f64 = 0;
    var m2: f64 = 0;
    var second = -std.math.inf(f64);
    for (0..h) |y| {
        for (0..w) |x| {
            if (x + excl >= px and x <= px + excl and y + excl >= py and y <= py + excl) continue;
            const v = scores[y * w + x];
            second = @max(second, v);
            n += 1;
            const d = v - mean;
            mean += d / @as(f64, @floatFromInt(n));
            m2 += d * (v - mean);
        }
    }
    if (n < 2) return .{ .psr = null, .margin = null };
    const peak = scores[py * w + px];
    const sd = @sqrt(m2 / @as(f64, @floatFromInt(n)));
    return .{ .psr = if (sd <= 0) null else (peak - mean) / sd, .margin = peak - second };
}

fn searchWindow(gpa: Allocator, img: Plane, tmpl: Plane, cx: usize, cy: usize, r: usize) Allocator.Error!Match {
    const it = try Integrals.init(gpa, img);
    defer it.deinit(gpa);
    const t = try Template.init(gpa, tmpl);
    defer t.deinit(gpa);
    const max_x = img.w - t.w;
    const max_y = img.h - t.h;
    var best: Match = .{ .x = @min(cx, max_x), .y = @min(cy, max_y), .peak = -std.math.inf(f64), .psr = null, .margin = null };
    var y = cy -| r;
    while (y <= @min(cy + r, max_y)) : (y += 1) {
        var x = cx -| r;
        while (x <= @min(cx + r, max_x)) : (x += 1) {
            const v = zncc(img, it, t, x, y);
            if (v > best.peak) {
                best.x = x;
                best.y = y;
                best.peak = v;
            }
        }
    }
    return best;
}

// ---- 複数フレームの投票 ------------------------------------------------------

pub const Thresholds = struct {
    /// 最頻位置の得票率の下限
    min_confidence: f64,
    /// 2 番手との差 (margin) の下限
    min_margin: f64,
    /// PSR の下限。0 なら判定に使わない
    min_psr: f64,
};

/// reliable = false の理由。利用者に見せる文は main.zig が持つ
pub const Reason = enum {
    low_confidence,
    low_margin,
    low_psr,
    /// 比べる相手の位置が無く margin を測れない。測れないものは reliable と言わない
    unmeasured_margin,
};

pub const Detection = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    /// 最頻位置の得票率
    confidence: f64,
    /// 最頻位置に投票したフレームの PSR の平均。1 フレームでも測れなければ null
    psr: ?f64,
    /// 最頻位置に投票したフレームの margin の平均。1 フレームでも測れなければ null
    margin: ?f64,
    /// 最頻位置に投票したフレームの peak の平均
    peak: f64,
    frames_voted: usize,
    reliable: bool,
    reasons: std.EnumSet(Reason),
};

pub const DetectError = error{NoFrames} || LocateError;

/// 各フレームで `reference` を探し、最頻位置を ROI とする。
/// 同数なら (y, x) の小さいほうを採って結果を決定的にする。
pub fn detect(gpa: Allocator, frames: []const Image, reference: Image, th: Thresholds) DetectError!Detection {
    if (frames.len == 0) return error.NoFrames;

    const tmpl = try feature(gpa, reference);
    defer tmpl.deinit(gpa);

    const Key = struct { x: usize, y: usize };
    const Acc = struct { count: usize = 0, psr: ?f64 = 0, margin: ?f64 = 0, peak: f64 = 0 };
    var votes: std.AutoArrayHashMapUnmanaged(Key, Acc) = .empty;
    defer votes.deinit(gpa);

    for (frames) |f| {
        const plane = try feature(gpa, f);
        defer plane.deinit(gpa);
        const m = try locate(gpa, plane, tmpl);
        const e = try votes.getOrPut(gpa, .{ .x = m.x, .y = m.y });
        if (!e.found_existing) e.value_ptr.* = .{};
        e.value_ptr.count += 1;
        e.value_ptr.psr = if (e.value_ptr.psr != null and m.psr != null) e.value_ptr.psr.? + m.psr.? else null;
        e.value_ptr.margin = if (e.value_ptr.margin != null and m.margin != null) e.value_ptr.margin.? + m.margin.? else null;
        e.value_ptr.peak += m.peak;
    }

    var best_key: Key = undefined;
    var best: Acc = .{};
    var iter = votes.iterator();
    while (iter.next()) |e| {
        const k = e.key_ptr.*;
        const a = e.value_ptr.*;
        const better = a.count > best.count or (a.count == best.count and
            (k.y < best_key.y or (k.y == best_key.y and k.x < best_key.x)));
        if (better) {
            best_key = k;
            best = a;
        }
    }

    const n: f64 = @floatFromInt(best.count);
    var d: Detection = .{
        .x = best_key.x,
        .y = best_key.y,
        .width = reference.width,
        .height = reference.height,
        .confidence = n / @as(f64, @floatFromInt(frames.len)),
        .psr = if (best.psr) |v| v / n else null,
        .margin = if (best.margin) |v| v / n else null,
        .peak = best.peak / n,
        .frames_voted = frames.len,
        .reliable = false,
        .reasons = .initEmpty(),
    };
    if (d.confidence < th.min_confidence) d.reasons.insert(.low_confidence);
    if (d.margin) |m| {
        if (m < th.min_margin) d.reasons.insert(.low_margin);
    } else d.reasons.insert(.unmeasured_margin);
    if (th.min_psr > 0 and (d.psr orelse 0) < th.min_psr) d.reasons.insert(.low_psr);
    d.reliable = d.reasons.count() == 0;
    return d;
}

fn feature(gpa: Allocator, img: Image) Allocator.Error!Plane {
    const g = try grayscale(gpa, img);
    defer g.deinit(gpa);
    return gradient(gpa, g);
}

/// 検出矩形と正解矩形の IoU。回帰テストの判定に使う
pub fn iou(ax: i64, ay: i64, aw: i64, ah: i64, bx: i64, by: i64, bw: i64, bh: i64) f64 {
    const ix = @max(0, @min(ax + aw, bx + bw) - @max(ax, bx));
    const iy = @max(0, @min(ay + ah, by + bh) - @max(ay, by));
    const inter: f64 = @floatFromInt(ix * iy);
    const uni: f64 = @floatFromInt(aw * ah + bw * bh - ix * iy);
    return if (uni <= 0) 0 else inter / uni;
}

// ---- tests -------------------------------------------------------------------

fn randomPlane(gpa: Allocator, w: usize, h: usize, seed: u64) !Plane {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const p = try Plane.init(gpa, w, h);
    for (p.px) |*v| v.* = r.float(f32) * 255;
    return p;
}

fn cropPlane(gpa: Allocator, p: Plane, x: usize, y: usize, w: usize, h: usize) !Plane {
    const c = try Plane.init(gpa, w, h);
    for (0..h) |j| @memcpy(c.px[j * w ..][0..w], p.px[(y + j) * p.w + x ..][0..w]);
    return c;
}

test "roi: locate finds an exact crop, including at the edges" {
    const gpa = std.testing.allocator;
    const img = try randomPlane(gpa, 640, 360, 1);
    defer img.deinit(gpa);
    const cases = [_][4]usize{
        .{ 493, 5, 142, 77 },
        .{ 0, 0, 64, 64 },
        .{ 640 - 32, 360 - 32, 32, 32 },
        .{ 200, 100, 300, 200 },
    };
    for (cases) |c| {
        const t = try cropPlane(gpa, img, c[0], c[1], c[2], c[3]);
        defer t.deinit(gpa);
        const m = try locate(gpa, img, t);
        std.testing.expectEqual(c[0], m.x) catch |e| {
            std.debug.print("crop {any}: got ({d},{d})\n", .{ c, m.x, m.y });
            return e;
        };
        try std.testing.expectEqual(c[1], m.y);
        try std.testing.expect(m.peak > 0.99);
    }
}

test "roi: locate rejects a template larger than the image or too small" {
    const gpa = std.testing.allocator;
    const img = try Plane.init(gpa, 64, 64);
    defer img.deinit(gpa);
    const big = try Plane.init(gpa, 65, 20);
    defer big.deinit(gpa);
    const tiny = try Plane.init(gpa, 20, min_template_side - 1);
    defer tiny.deinit(gpa);
    try std.testing.expectError(error.TemplateLargerThanImage, locate(gpa, img, big));
    try std.testing.expectError(error.TemplateTooSmall, locate(gpa, img, tiny));
}

test "roi: an exact duplicate drives margin to zero, while PSR stays high" {
    // 画面内に同じ模様が 2 つあると、どちらに当たっても不思議ではない。
    // PSR は分布全体に対する突出度なので、競合相手が 1 か所増えてもほとんど動かない
    // (観測: 12.11 → 11.79)。margin は 2 番手との差なので 0 になる (0.749 → 0.000)。
    // PSR 単独で reliable を決めない理由 (docs/SPEC.md §2-1)。
    // 複製先は粗い階層でも画素が揃うよう 4 の倍数に置く (揃わないと縮小で別の模様になる)
    const gpa = std.testing.allocator;
    const base = try randomPlane(gpa, 320, 240, 2);
    defer base.deinit(gpa);
    const patch = try cropPlane(gpa, base, 20, 20, 48, 48);
    defer patch.deinit(gpa);
    const unique = try locate(gpa, base, patch);

    const dup = try Plane.init(gpa, base.w, base.h);
    defer dup.deinit(gpa);
    @memcpy(dup.px, base.px);
    for (0..patch.h) |j| @memcpy(dup.px[(152 + j) * dup.w + 200 ..][0..patch.w], patch.px[j * patch.w ..][0..patch.w]);
    const duped = try locate(gpa, dup, patch);

    try std.testing.expect(unique.margin.? > 0.5);
    try std.testing.expect(duped.margin.? < 0.01);
    try std.testing.expect(duped.psr.? > 0.9 * unique.psr.?);
}

test "roi: a flat reference is rejected, and a search with no other position cannot be reliable" {
    const gpa = std.testing.allocator;
    const img = try randomPlane(gpa, 64, 48, 5);
    defer img.deinit(gpa);
    const flat = try Plane.init(gpa, 20, 20);
    defer flat.deinit(gpa);
    @memset(flat.px, 7);
    try std.testing.expectError(error.FlatTemplate, locate(gpa, img, flat));

    // 参照画像が画像と同じ大きさなら、照合できる位置は 1 つしかなく、margin は測れない
    const m = try locate(gpa, img, img);
    try std.testing.expectEqual(@as(?f64, null), m.margin);
    try std.testing.expectEqual(@as(?f64, null), m.psr);
}

test "roi: iou" {
    try std.testing.expectEqual(@as(f64, 1), iou(10, 10, 20, 20, 10, 10, 20, 20));
    try std.testing.expectEqual(@as(f64, 0), iou(0, 0, 10, 10, 10, 0, 10, 10));
    // 半分ずれ: 交差 50、和集合 150
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), iou(0, 0, 10, 10, 5, 0, 10, 10), 1e-12);
}

fn solidRgb(gpa: Allocator, w: u32, h: u32, plane: Plane) ![]u8 {
    const rgb = try gpa.alloc(u8, @as(usize, w) * h * 3);
    for (plane.px, 0..) |v, i| {
        const b: u8 = @intFromFloat(v);
        rgb[i * 3 ..][0..3].* = .{ b, b, b };
    }
    return rgb;
}

test "roi: detect votes for the fixed position even when some frames miss" {
    const gpa = std.testing.allocator;
    const w = 160;
    const h = 120;
    // 各フレームは背景がまったく違い、(100, 30) に同じ模様がある。1 枚だけ模様の無いフレームを混ぜる
    const mark = try randomPlane(gpa, 40, 24, 99);
    defer mark.deinit(gpa);
    var frames: [5]Image = undefined;
    var bufs: [5][]u8 = undefined;
    defer for (bufs) |b| gpa.free(b);
    for (0..5) |i| {
        const bg = try randomPlane(gpa, w, h, 1000 + i);
        defer bg.deinit(gpa);
        if (i != 2) for (0..mark.h) |j| @memcpy(bg.px[(30 + j) * w + 100 ..][0..mark.w], mark.px[j * mark.w ..][0..mark.w]);
        bufs[i] = try solidRgb(gpa, w, h, bg);
        frames[i] = .{ .width = w, .height = h, .rgb = bufs[i] };
    }
    const ref_rgb = try solidRgb(gpa, 40, 24, mark);
    defer gpa.free(ref_rgb);

    const d = try detect(gpa, &frames, .{ .width = 40, .height = 24, .rgb = ref_rgb }, .{
        .min_confidence = 0.5,
        .min_margin = 0.05,
        .min_psr = 0,
    });
    try std.testing.expectEqual(@as(usize, 100), d.x);
    try std.testing.expectEqual(@as(usize, 30), d.y);
    try std.testing.expectEqual(@as(usize, 40), d.width);
    try std.testing.expectEqual(@as(usize, 24), d.height);
    try std.testing.expectEqual(@as(f64, 0.8), d.confidence);
    try std.testing.expectEqual(@as(usize, 5), d.frames_voted);
    try std.testing.expect(d.reliable);

    // 得票率の下限を上げると、理由付きで reliable=false になる
    const strict = try detect(gpa, &frames, .{ .width = 40, .height = 24, .rgb = ref_rgb }, .{
        .min_confidence = 0.9,
        .min_margin = 0.05,
        .min_psr = 0,
    });
    try std.testing.expect(!strict.reliable);
    try std.testing.expect(strict.reasons.contains(.low_confidence));
    try std.testing.expect(!strict.reasons.contains(.low_margin));
}
