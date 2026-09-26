//! Temporal Recovery: ウォーターマークに隠れた画素を、別のフレームに実際に写っている画素で戻す。
//!
//! 生成する前に、映像内にある証拠から復元する（CLAUDE.md §1）。背景が動いていれば、ある時点で隠れた
//! 画素は別の時点ではウォーターマークの外に出ている。フレーム間の動きを推定して、その実画素を持ってくる。
//!
//! 今回の範囲（docs/SPEC.md）:
//! - 動きは画面全体の平行移動だけ（整数画素）。位相相関で隣り合うフレームの間を推定し、累積する
//! - 相関のピークが低いペアは「推定できなかった」として鎖を切る。そこに 0 を入れない
//!   （入れると以降の累積がすべて狂う。mp4tool で観測: 1 フレームの棄却で SSIM 0.992 → 0.886）
//! - 戻せない画素は未復元として残し、マスクで返す。周囲からの内挿（Spatial）はしない
//!
//! ROI は検出済みの固定矩形（roi.zig）。この module は FFmpeg に依存しない。

const std = @import("std");
const Allocator = std.mem.Allocator;
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// RGB24 で詰めた画像
pub const Image = struct {
    width: u32,
    height: u32,
    rgb: []const u8,
};

// ---- FFT ---------------------------------------------------------------------

const Complex = std.math.Complex(f64);

/// その場で計算する基数 2 の FFT。`inverse` なら逆変換（1/n はかけない）
fn fft(a: []Complex, inverse: bool) void {
    const n = a.len;
    std.debug.assert(std.math.isPowerOfTwo(n));
    // ビット反転の並べ替え
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std.mem.swap(Complex, &a[i], &a[j]);
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = 2 * std.math.pi / @as(f64, @floatFromInt(len)) * @as(f64, if (inverse) 1 else -1);
        const wl = Complex.init(@cos(ang), @sin(ang));
        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = Complex.init(1, 0);
            for (0..len / 2) |k| {
                const u = a[i + k];
                const v = a[i + k + len / 2].mul(w);
                a[i + k] = u.add(v);
                a[i + k + len / 2] = u.sub(v);
                w = w.mul(wl);
            }
        }
    }
}

/// 2 次元 FFT（行、次に列）。`col` は長さ h の作業領域
fn fft2(a: []Complex, w: usize, h: usize, col: []Complex, inverse: bool) void {
    for (0..h) |y| fft(a[y * w ..][0..w], inverse);
    for (0..w) |x| {
        for (0..h) |y| col[y] = a[y * w + x];
        fft(col, inverse);
        for (0..h) |y| a[y * w + x] = col[y];
    }
}

// ---- 動きの推定 --------------------------------------------------------------

pub const Shift = struct {
    /// cur(x) ≈ prev(x - d): 背景が d だけ動いた
    dx: i32,
    dy: i32,
    /// 位相相関のピークの高さ（0..1）。高いほど 1 つの平行移動でよく説明できる
    peak: f64,
};

/// 位相相関に使う窓（画面内の矩形、幅・高さは 2 の冪）を、`exclude` と重ならない所から選ぶ。
///
/// 固定のウォーターマークは「動いていない」成分なので推定に入れない。ROI を塗りつぶして除く方法は、
/// 塗った矩形の縁がどのフレームでも同じ位置にある模様になるので採らない（この影響を単独では測っていない）。
///
/// 候補は大きい順に、画面の端と ROI の上下左右に接する位置。面積が最大のものを採る。
/// 取れなければ（ROI が画面を覆っている）null
pub fn chooseWindow(w: u32, h: u32, exclude: ?Rect) ?Rect {
    const max_side = 1024;
    var best: ?Rect = null;
    var sw: u32 = 1;
    while (sw * 2 <= w and sw * 2 <= max_side) sw *= 2;
    while (sw >= 32) : (sw /= 2) {
        var sh: u32 = 1;
        while (sh * 2 <= h and sh * 2 <= max_side) sh *= 2;
        while (sh >= 32) : (sh /= 2) {
            if (best) |bb| if (@as(u64, sw) * sh <= @as(u64, bb.w) * bb.h) continue;
            const r = exclude orelse {
                best = .{ .x = (w - sw) / 2, .y = (h - sh) / 2, .w = sw, .h = sh };
                continue;
            };
            const xs = [_]i64{ @divTrunc(@as(i64, w) - sw, 2), 0, @as(i64, w) - sw, @as(i64, r.x) + r.w, @as(i64, r.x) - sw };
            const ys = [_]i64{ @divTrunc(@as(i64, h) - sh, 2), 0, @as(i64, h) - sh, @as(i64, r.y) + r.h, @as(i64, r.y) - sh };
            for (ys) |y| for (xs) |x| {
                if (x < 0 or y < 0 or x + sw > w or y + sh > h) continue;
                const overlap = x < @as(i64, r.x) + r.w and x + sw > r.x and y < @as(i64, r.y) + r.h and y + sh > r.y;
                if (overlap) continue;
                best = .{ .x = @intCast(x), .y = @intCast(y), .w = sw, .h = sh };
                break;
            };
        }
    }
    return best;
}

/// 輝度（BT.601）の平面を窓で切り出し、平均を引いて Hann 窓をかける
fn preparePlane(gpa: Allocator, img: Image, win: Rect) ![]Complex {
    const ww = win.w;
    const wh = win.h;
    const buf = try gpa.alloc(Complex, @as(usize, ww) * wh);
    var sum: f64 = 0;
    for (0..wh) |y| for (0..ww) |x| {
        const i = ((win.y + y) * img.width + win.x + x) * 3;
        const v = 0.299 * @as(f64, @floatFromInt(img.rgb[i])) + 0.587 * @as(f64, @floatFromInt(img.rgb[i + 1])) + 0.114 * @as(f64, @floatFromInt(img.rgb[i + 2]));
        buf[y * ww + x] = Complex.init(v, 0);
        sum += v;
    };
    const mean = sum / @as(f64, @floatFromInt(buf.len));
    for (0..wh) |y| for (0..ww) |x| {
        const hx = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(ww)));
        const hy = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(wh)));
        buf[y * ww + x] = Complex.init((buf[y * ww + x].re - mean) * hx * hy, 0);
    };
    return buf;
}

/// 位相相関で使う周波数の上限（cycles/px）。
///
/// ⚠ x264 などのブロック符号化は、16 px（マクロブロック）の格子状のノイズをどのフレームでも同じ位置に作る。
/// 位相相関は全周波数を同じ重みにするので、この格子が「動いていない」(0,0) のピークを作る。
/// 合成 crf 35・パン 3,1 px/フレームで、全帯域では 0/59 ペア、上限 0.1 で 13/59、0.06 で 56/59 が正しかった
/// （numpy で同じ計算をして観測。docs/SPEC.md §4）。1/16 = 0.0625 のすぐ下に置いて格子の基本周波数から落とす
const max_freq = 0.06;

/// `prev` から `cur` への平行移動を位相相関で推定する。窓は `exclude`（ウォーターマークの ROI）の外から取る。
/// 窓が取れなければ peak 0（推定できなかった）を返す。
pub fn estimateShift(gpa: Allocator, prev: Image, cur: Image, exclude: ?Rect) !Shift {
    std.debug.assert(prev.width == cur.width and prev.height == cur.height);
    const win = chooseWindow(prev.width, prev.height, exclude) orelse return .{ .dx = 0, .dy = 0, .peak = 0 };
    const ww: usize = win.w;
    const wh: usize = win.h;
    const a = try preparePlane(gpa, prev, win);
    defer gpa.free(a);
    const b = try preparePlane(gpa, cur, win);
    defer gpa.free(b);
    const col = try gpa.alloc(Complex, wh);
    defer gpa.free(col);
    fft2(a, ww, wh, col, false);
    fft2(b, ww, wh, col, false);
    // 正規化した相互パワースペクトル: B · conj(A) / |B · conj(A)|。低い周波数だけを残す
    var kept: usize = 0;
    for (0..wh) |y| for (0..ww) |x| {
        const i = y * ww + x;
        const fy = @as(f64, @floatFromInt(@min(y, wh - y))) / @as(f64, @floatFromInt(wh));
        const fx = @as(f64, @floatFromInt(@min(x, ww - x))) / @as(f64, @floatFromInt(ww));
        const r = b[i].mul(a[i].conjugate());
        const m = r.magnitude();
        if (fx > max_freq or fy > max_freq or m <= 1e-12) {
            a[i] = Complex.init(0, 0);
        } else {
            a[i] = Complex.init(r.re / m, r.im / m);
            kept += 1;
        }
    };
    fft2(a, ww, wh, col, true);
    // 残した成分がすべて同じ移動を指していれば 1 になるよう、残した数で割る
    const n: f64 = @floatFromInt(ww * wh);
    const k: f64 = @floatFromInt(@max(kept, 1));
    var best: usize = 0;
    for (a, 0..) |v, i| {
        if (v.re > a[best].re) best = i;
    }
    const px = best % ww;
    const py = best / ww;
    // 窓の半分より先は負の移動（巡回するため）
    const dx: i32 = if (px > ww / 2) @as(i32, @intCast(px)) - @as(i32, @intCast(ww)) else @intCast(px);
    const dy: i32 = if (py > wh / 2) @as(i32, @intCast(py)) - @as(i32, @intCast(wh)) else @intCast(py);
    return .{ .dx = dx, .dy = dy, .peak = a[best].re / n * (n / k) };
}

// ---- 復元 --------------------------------------------------------------------

/// 窓の中の各フレームの位置。隣り合うフレームの移動量を累積したもの。
/// 推定できなかったペアで鎖が切れるので、`segment` が同じフレームどうしだけ比べられる
pub const Track = struct {
    /// フレーム 0 を原点とした背景の累積移動量
    offset: [][2]i32,
    segment: []u32,

    /// `shifts[i]` はフレーム i から i+1 への移動。`min_peak` 未満のペアは鎖を切る
    pub fn build(gpa: Allocator, shifts: []const Shift, min_peak: f64) !Track {
        const n = shifts.len + 1;
        const offset = try gpa.alloc([2]i32, n);
        errdefer gpa.free(offset);
        const segment = try gpa.alloc(u32, n);
        offset[0] = .{ 0, 0 };
        segment[0] = 0;
        for (shifts, 0..) |s, i| {
            if (s.peak >= min_peak) {
                offset[i + 1] = .{ offset[i][0] + s.dx, offset[i][1] + s.dy };
                segment[i + 1] = segment[i];
            } else {
                // 推定できなかった。累積は続けられないので新しい区間を始める（0 を入れて続けない）
                offset[i + 1] = .{ 0, 0 };
                segment[i + 1] = segment[i] + 1;
            }
        }
        return .{ .offset = offset, .segment = segment };
    }

    pub fn deinit(t: Track, gpa: Allocator) void {
        gpa.free(t.offset);
        gpa.free(t.segment);
    }
};

/// 由来ごとの画素数（provenance.zig）。coverage は Tally.coverage()
pub const Recovered = provenance.Tally;

/// フレーム `target` の ROI の画素を、別のフレームの実画素で戻して `out`（RGB24、target と同じ大きさ）に書く。
/// `prov`（1 画素 1 つ、フレーム全体）には各画素の由来を書く: ROI の外は original、戻せた画素は temporal_real、
/// 戻せなかった ROI の画素は unrecovered。戻せなかった画素は target の画素のまま残す（推測で埋めない）。
///
/// 候補は時間の近いフレームから順に見る。背景の同じ点がそのフレームで ROI の外かつ画面内にあれば採る。
pub fn recoverFrame(frames: []const Image, track: Track, target: usize, roi: Rect, max_ring_diff: ?f64, out: []u8, prov: []Provenance) Recovered {
    const t = frames[target];
    const w = t.width;
    const h = t.height;
    @memcpy(out, t.rgb);
    @memset(prov, .original);
    var tally: Recovered = .{};

    // 使ってよいフレーム: 鎖がつながっていて、ROI の周りの帯が表示中のフレームと合うもの
    std.debug.assert(frames.len <= max_window_frames);
    var usable: [max_window_frames]bool = undefined;
    for (0..frames.len) |s| {
        usable[s] = s != target and track.segment[s] == track.segment[target];
        if (!usable[s]) continue;
        if (max_ring_diff) |limit| {
            const d = ringDiff(t, frames[s], roi, track.offset[s][0] - track.offset[target][0], track.offset[s][1] - track.offset[target][1]);
            usable[s] = if (d) |v| v <= limit else false;
        }
    }
    for (roi.y..roi.y + roi.h) |y| {
        for (roi.x..roi.x + roi.w) |x| {
            prov[y * w + x] = .unrecovered;
            var dist: usize = 1;
            search: while (dist < frames.len) : (dist += 1) {
                for ([_]i64{ -1, 1 }) |sign| {
                    const si = @as(i64, @intCast(target)) + sign * @as(i64, @intCast(dist));
                    if (si < 0 or si >= frames.len) continue;
                    const s: usize = @intCast(si);
                    if (!usable[s]) continue;
                    // 背景の同じ点は、フレーム s では x + (D[s] - D[target]) にある
                    const sx = @as(i64, @intCast(x)) + track.offset[s][0] - track.offset[target][0];
                    const sy = @as(i64, @intCast(y)) + track.offset[s][1] - track.offset[target][1];
                    if (sx < 0 or sy < 0 or sx >= w or sy >= h) continue;
                    const ux: usize = @intCast(sx);
                    const uy: usize = @intCast(sy);
                    if (ux >= roi.x and ux < roi.x + roi.w and uy >= roi.y and uy < roi.y + roi.h) continue;
                    const src = (uy * w + ux) * 3;
                    @memcpy(out[(y * w + x) * 3 ..][0..3], frames[s].rgb[src..][0..3]);
                    prov[y * w + x] = .temporal_real;
                    break :search;
                }
            }
            tally.add(prov[y * w + x]);
        }
    }
    // ROI の外は数えない（Tally.roiPixels は ROI の中だけ）
    return tally;
}

/// 窓の最大フレーム数（前後 255 枚まで）
pub const max_window_frames = 511;

/// 帯の幅（px）
const ring_band = 6;

/// 表示中のフレーム `t` の ROI のすぐ外側（幅 ring_band）の画素と、フレーム `s` を (dx, dy) ずらした所の画素の
/// 差の絶対値の平均（R/G/B）。帯は両方のフレームで実際の背景が見えている所なので、推定した移動が
/// ROI の近くで本当に合っているかをここで確かめる。
///
/// 動きが画面全体の平行移動でない（手持ちの揺れ・被写体の動き・ズーム）と、累積した移動量は ROI の近くで
/// 合わない。そのフレームから画素を借りると、正しくない画素を「戻した」と言ってしまう（手持ちの実写で観測）。
/// 比べられる画素が帯の 1/4 未満なら確かめられないとして null
fn ringDiff(t: Image, s: Image, roi: Rect, dx: i32, dy: i32) ?f64 {
    const w: i64 = t.width;
    const h: i64 = t.height;
    const x0: i64 = @as(i64, roi.x) - ring_band;
    const y0: i64 = @as(i64, roi.y) - ring_band;
    const x1: i64 = @as(i64, roi.x) + roi.w + ring_band;
    const y1: i64 = @as(i64, roi.y) + roi.h + ring_band;
    var sum: u64 = 0;
    var n: u64 = 0;
    var total: u64 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const in_roi = x >= roi.x and x < @as(i64, roi.x) + roi.w and y >= roi.y and y < @as(i64, roi.y) + roi.h;
            if (in_roi) continue;
            total += 1;
            if (x < 0 or y < 0 or x >= w or y >= h) continue;
            const sx = x + dx;
            const sy = y + dy;
            if (sx < 0 or sy < 0 or sx >= w or sy >= h) continue;
            if (sx >= roi.x and sx < @as(i64, roi.x) + roi.w and sy >= roi.y and sy < @as(i64, roi.y) + roi.h) continue;
            const it = (@as(usize, @intCast(y)) * t.width + @as(usize, @intCast(x))) * 3;
            const is = (@as(usize, @intCast(sy)) * s.width + @as(usize, @intCast(sx))) * 3;
            for (0..3) |c| sum += @abs(@as(i32, t.rgb[it + c]) - @as(i32, s.rgb[is + c]));
            n += 3;
        }
    }
    if (n / 3 * 4 < total) return null;
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
}

/// 手元にある連続したフレーム列から、`target` を戻す（移動の推定・鎖・復元をまとめて行う）。
/// GUI のように窓を丸ごと持っている呼び出し側用。CLI（restore_cmd.zig）は流しながら同じ部品を使う
pub fn recoverInWindow(gpa: Allocator, frames: []const Image, target: usize, roi: Rect, min_peak: f64, max_ring_diff: ?f64, out: []u8, prov: []Provenance) !Recovered {
    const shifts = try gpa.alloc(Shift, frames.len - 1);
    defer gpa.free(shifts);
    for (shifts, 0..) |*s, i| s.* = try estimateShift(gpa, frames[i], frames[i + 1], roi);
    const track = try Track.build(gpa, shifts, min_peak);
    defer track.deinit(gpa);
    return recoverFrame(frames, track, target, roi, max_ring_diff, out, prov);
}

// ---- tests -------------------------------------------------------------------

/// 大きな乱数模様から (ox, oy) で w x h を切り出す。滑らかにするため 4x4 のブロックで塗る
fn scene(gpa: Allocator, sw: u32, sh: u32, seed: u64) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const buf = try gpa.alloc(u8, @as(usize, sw) * sh * 3);
    const bw = sw / 4 + 1;
    const blocks = try gpa.alloc(u8, bw * (sh / 4 + 1) * 3);
    defer gpa.free(blocks);
    prng.random().bytes(blocks);
    for (0..sh) |y| for (0..sw) |x| for (0..3) |c| {
        buf[(y * sw + x) * 3 + c] = blocks[((y / 4) * bw + x / 4) * 3 + c];
    };
    return buf;
}

fn view(gpa: Allocator, s: []const u8, sw: u32, ox: u32, oy: u32, w: u32, h: u32) ![]u8 {
    const out = try gpa.alloc(u8, @as(usize, w) * h * 3);
    for (0..h) |y| @memcpy(out[y * w * 3 ..][0 .. w * 3], s[((oy + y) * sw + ox) * 3 ..][0 .. w * 3]);
    return out;
}

test "temporal: fft round-trips" {
    var a: [8]Complex = undefined;
    for (&a, 0..) |*v, i| v.* = Complex.init(@floatFromInt(i * i), @floatFromInt(i));
    const orig = a;
    fft(&a, false);
    fft(&a, true);
    for (a, orig) |v, o| {
        try std.testing.expectApproxEqAbs(o.re, v.re / 8, 1e-9);
        try std.testing.expectApproxEqAbs(o.im, v.im / 8, 1e-9);
    }
}

test "temporal: estimateShift finds a pan in every direction, ignoring a fixed watermark" {
    const gpa = std.testing.allocator;
    const s = try scene(gpa, 400, 300, 7);
    defer gpa.free(s);
    const prev_rgb = try view(gpa, s, 400, 100, 80, 160, 96);
    defer gpa.free(prev_rgb);
    const wm: Rect = .{ .x = 100, .y = 10, .w = 50, .h = 20 };
    for ([_][2]i32{ .{ 7, 3 }, .{ -5, 2 }, .{ 0, -9 }, .{ 12, 0 } }) |d| {
        // 背景が d 動く = カメラの窓が -d 動く
        const cur_rgb = try view(gpa, s, 400, @intCast(100 - d[0]), @intCast(80 - d[1]), 160, 96);
        defer gpa.free(cur_rgb);
        // 両方の同じ位置に同じ「ウォーターマーク」を焼く
        for ([_][]u8{ prev_rgb, cur_rgb }) |img| {
            for (wm.y..wm.y + wm.h) |y| for (wm.x..wm.x + wm.w) |x| {
                img[(y * 160 + x) * 3 ..][0..3].* = .{ 255, 255, 255 };
            };
        }
        const got = try estimateShift(gpa, .{ .width = 160, .height = 96, .rgb = prev_rgb }, .{ .width = 160, .height = 96, .rgb = cur_rgb }, wm);
        std.testing.expectEqual(d, [2]i32{ got.dx, got.dy }) catch |e| {
            std.debug.print("want {any}, got ({d},{d}) peak {d:.3}\n", .{ d, got.dx, got.dy, got.peak });
            return e;
        };
        try std.testing.expect(got.peak > 0.8);
    }
}

test "temporal: chooseWindow keeps the window off the ROI and takes the largest" {
    // ROI 無し: 画面に収まる最大の 2 の冪を中央に
    try std.testing.expectEqual(Rect{ .x = 64, .y = 52, .w = 512, .h = 256 }, chooseWindow(640, 360, null).?);
    // 右上の角の ROI（合成の既定の位置）: 重ならない最大の窓
    const corner: Rect = .{ .x = 481, .y = 0, .w = 158, .h = 68 };
    // ROI の下（y = 68）に 512x256 が収まる
    try std.testing.expectEqual(Rect{ .x = 64, .y = 68, .w = 512, .h = 256 }, chooseWindow(640, 360, corner).?);
    // 中央の ROI
    const center: Rect = .{ .x = 234, .y = 144, .w = 158, .h = 68 };
    const wm = chooseWindow(640, 360, center).?;
    const overlap = wm.x < center.x + center.w and wm.x + wm.w > center.x and wm.y < center.y + center.h and wm.y + wm.h > center.y;
    try std.testing.expect(!overlap);
    // 画面をほぼ覆う ROI では窓が取れない
    try std.testing.expectEqual(@as(?Rect, null), chooseWindow(64, 64, .{ .x = 10, .y = 10, .w = 44, .h = 44 }));
}

test "temporal: unrelated frames give a low peak" {
    const gpa = std.testing.allocator;
    const a = try scene(gpa, 160, 96, 1);
    defer gpa.free(a);
    const b = try scene(gpa, 160, 96, 2);
    defer gpa.free(b);
    const got = try estimateShift(gpa, .{ .width = 160, .height = 96, .rgb = a }, .{ .width = 160, .height = 96, .rgb = b }, null);
    // 観測: 無関係 0.310、上のテストの正しい推定 0.836〜0.967（窓 128x64）。窓が小さいと残る低い周波数の
    // 成分が少なく、無関係でもピークが上がる。使う閾値は動画で較正する（docs/SPEC.md §4）
    try std.testing.expect(got.peak < 0.5);
}

test "temporal: Track cuts the chain at an unestimated pair instead of assuming no motion" {
    const gpa = std.testing.allocator;
    const t = try Track.build(gpa, &.{
        .{ .dx = 3, .dy = 1, .peak = 0.9 },
        .{ .dx = 3, .dy = 1, .peak = 0.01 }, // 推定できなかった
        .{ .dx = 3, .dy = 1, .peak = 0.9 },
    }, 0.1);
    defer t.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1 }, t.segment);
    try std.testing.expectEqual([2]i32{ 3, 1 }, t.offset[1]);
    try std.testing.expectEqual([2]i32{ 3, 1 }, t.offset[3]);
}

test "temporal: recoverFrame restores the exact background under a pan, refuses frames whose surroundings do not match, and reports what it could not" {
    const gpa = std.testing.allocator;
    const sw = 400;
    const s = try scene(gpa, sw, 200, 3);
    defer gpa.free(s);
    const w = 120;
    const h = 64;
    const roi: Rect = .{ .x = 40, .y = 20, .w = 30, .h = 16 };
    // 背景が 1 フレームに +6 px（右へ）動く 9 フレーム。ROI は塗りつぶす
    var bufs: [9][]u8 = undefined;
    var frames: [9]Image = undefined;
    var shifts: [8]Shift = undefined;
    defer for (bufs) |b| gpa.free(b);
    for (0..9) |k| {
        bufs[k] = try view(gpa, s, sw, @intCast(200 - 6 * k), 60, w, h);
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
            bufs[k][(y * w + x) * 3 ..][0..3].* = .{ 255, 0, 255 };
        };
        frames[k] = .{ .width = w, .height = h, .rgb = bufs[k] };
    }
    for (0..8) |k| shifts[k] = .{ .dx = 6, .dy = 0, .peak = 1 };
    const track = try Track.build(gpa, &shifts, 0.1);
    defer track.deinit(gpa);

    const out = try gpa.alloc(u8, w * h * 3);
    defer gpa.free(out);
    const prov = try gpa.alloc(Provenance, w * h);
    defer gpa.free(prov);
    const truth = try view(gpa, s, sw, 200 - 6 * 4, 60, w, h);
    defer gpa.free(truth);

    // 中央のフレームは前後 4 フレームずつ（±24 px）使える。ROI の幅 30 のうち、左右どちらかに出る画素だけ戻る
    const r = recoverFrame(&frames, track, 4, roi, null, out, prov);
    try std.testing.expectEqual(@as(usize, 30 * 16), r.roiPixels());
    // ROI の外は original（入力のまま）
    try std.testing.expectEqual(Provenance.original, prov[0]);
    try std.testing.expectEqual(@as(usize, w * h - 30 * 16), std.mem.count(Provenance, prov, &.{.original}));
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        const i = y * w + x;
        if (prov[i] == .temporal_real) {
            // 戻したと言った画素は、正解と完全に一致する
            try std.testing.expectEqualSlices(u8, truth[i * 3 ..][0..3], out[i * 3 ..][0..3]);
        } else {
            // 戻せなかった画素は unrecovered で、焼かれたまま残す
            try std.testing.expectEqual(Provenance.unrecovered, prov[i]);
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255 }, out[i * 3 ..][0..3]);
        }
    };
    // 右へ 24 px 動いたフレームで x+24 >= 70 なら ROI の外 → x >= 46。左へ 24 px なら x-24 < 40 → x < 64。
    // よって全列が戻る
    try std.testing.expectEqual(r.roiPixels(), r.recovered());
    try std.testing.expectEqual(@as(usize, 0), r.counts.get(.unrecovered));

    // 推定した移動量が間違っている（実際は +6、推定は +9）と、帯の確認をしなければ間違った画素を貼る。
    // 帯の確認をすれば、帯が合わないので借りない
    for (&shifts) |*sh| sh.* = .{ .dx = 9, .dy = 0, .peak = 1 };
    const wrong = try Track.build(gpa, &shifts, 0.1);
    defer wrong.deinit(gpa);
    const r_wrong = recoverFrame(&frames, wrong, 4, roi, null, out, prov);
    try std.testing.expect(r_wrong.recovered() > 0);
    var mismatched: usize = 0;
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        const i = y * w + x;
        if (prov[i] == .temporal_real and !std.mem.eql(u8, truth[i * 3 ..][0..3], out[i * 3 ..][0..3])) mismatched += 1;
    };
    try std.testing.expect(mismatched > 0);
    const r_checked = recoverFrame(&frames, wrong, 4, roi, 6, out, prov);
    try std.testing.expectEqual(@as(usize, 0), r_checked.recovered());
    try std.testing.expectEqual(r_checked.roiPixels(), r_checked.counts.get(.unrecovered));
    // 正しい移動量なら、帯の確認をしても全部戻る
    try std.testing.expectEqual(r.roiPixels(), recoverFrame(&frames, track, 4, roi, 6, out, prov).recovered());

    // 動いていなければ何も戻らない（同じ場所が隠れたまま）
    for (&shifts) |*sh| sh.* = .{ .dx = 0, .dy = 0, .peak = 1 };
    const still = try Track.build(gpa, &shifts, 0.1);
    defer still.deinit(gpa);
    const r0 = recoverFrame(&frames, still, 4, roi, null, out, prov);
    try std.testing.expectEqual(@as(usize, 0), r0.recovered());
}
