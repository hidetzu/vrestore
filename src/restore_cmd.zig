//! `vrestore restore`: 検出済みの ROI を、前後のフレームの実画素で戻す（Temporal Recovery）。
//!
//! 動画を先頭から流し、前後 `window` 枚ずつだけをメモリに持つ（2 時間ものでも一定）。
//! 出力は RGB24 の生フレーム。エンコードはしない（MP4 の書き出しは範囲外。ffmpeg に渡す）。
//! 復元のロジックは temporal.zig、デコードは video.zig、ROI は detect-roi の JSON をそのまま読む。

const std = @import("std");
const Io = std.Io;
const video = @import("video.zig");
const temporal = @import("temporal.zig");
const provenance = @import("provenance.zig");
const motion = @import("motion.zig");
const spatial = @import("spatial.zig");
const wmask = @import("wmask.zig");
const mp4 = @import("mp4.zig");
const stabilize = @import("stabilize.zig");
const debug_view = @import("debug_view.zig");

/// ROI の中でウォーターマークの画素だけを隠れている扱いにするか（wmask.zig）。none なら ROI 全体を隠す。
/// ⚠ 較正は docs/SPEC.md §4、決定は docs/adr/0010
pub const MaskMode = enum { none, auto };
pub const progress_every = 15;

/// --out の MP4 に元の音声を入れるか
pub const AudioMode = enum { copy, none };
pub const default_mask: MaskMode = .none;
/// マスクを推定するときに動画全体から取るフレーム数
pub const mask_frames = 60;
/// マスクを推定して埋める範囲は、ROI を上下左右にこれだけ広げたもの（動画の端で止める）。指定した範囲が
/// ウォーターマークより少し狭くても、はみ出した文字の端を隠せる。ウォーターマークでない画素は入力のまま残る。
/// Temporal は広げない: 広げると、背景がより遠くまで動かないと見えないので戻せる画素が減る
/// （合成の遅いパンで、同じ範囲の temporal_real が 430049 → 307902 画素）
pub const mask_margin = 8;

/// マスクを推定して埋める範囲。マスクを使うときだけ `mask_margin` 広げる
pub fn maskArea(mask: MaskMode, r: temporal.Rect, frame_w: u32, frame_h: u32) temporal.Rect {
    if (mask == .none) return r;
    return expand(r, mask_margin, frame_w, frame_h);
}

/// `r` を上下左右に `m` px 広げる（動画の端で止める）
pub fn expand(r: temporal.Rect, m: u32, frame_w: u32, frame_h: u32) temporal.Rect {
    const x0 = r.x -| m;
    const y0 = r.y -| m;
    const x1 = @min(frame_w, r.x + r.w + m);
    const y1 = @min(frame_h, r.y + r.h + m);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// マスクを使わないとき、別のフレームから借りない範囲（ROI をこれだけ広げたもの）。
/// ROI の外にはみ出したウォーターマークの縁を借りないため（temporal.Guard）
pub const default_temporal_guard = mask_margin;

/// 別のフレームから借りない範囲: マスクを使えるならマスクで隠した画素、使えなければ ROI を `guard_px` 広げた範囲
pub fn temporalGuard(hidden: ?Hidden, roi: temporal.Rect, guard_px: u32, frame_w: u32, frame_h: u32) temporal.Guard {
    if (hidden) |m| return .{ .area = m.area, .hidden = m.mask };
    return .{ .area = expand(roi, guard_px, frame_w, frame_h) };
}

test "maskArea: widens only with the mask, and stops at the frame edge" {
    const r: temporal.Rect = .{ .x = 500, .y = 7, .w = 113, .h = 69 };
    try std.testing.expectEqual(r, maskArea(.none, r, 640, 360));
    try std.testing.expectEqual(temporal.Rect{ .x = 492, .y = 0, .w = 129, .h = 84 }, maskArea(.auto, r, 640, 360));
    try std.testing.expectEqual(temporal.Rect{ .x = 492, .y = 0, .w = 128, .h = 84 }, maskArea(.auto, r, 620, 360));
}

/// 戻せなかった画素を周囲から推測して埋めるか（spatial.zig）。埋めた画素の由来は spatial_inpainted。
/// ⚠ 較正は docs/SPEC.md §4、決定は docs/adr/0008
pub const default_fill: spatial.Method = .none;

/// フレーム間の動きのモデル
pub const MotionModel = enum {
    /// 画面全体の整数画素の平行移動（位相相関）
    translation,
    /// 平行移動 + 回転 + 拡大縮小（ブロックの動きに RANSAC で当てはめる、motion.zig）
    affine,
};

/// affine を既定にする: 手持ちの実写で外れた画素が 1.76% → 0.24%、合成の回転 + パンで SSIM 0.46 → 0.81、
/// 平行移動だけの合成では同等。代わりに角の ROI の coverage が下がる（パン 7,3: 0.426 → 0.367）。
/// ⚠ 較正は docs/SPEC.md §4、決定は docs/adr/0007
pub const default_motion: MotionModel = .affine;

/// 位相相関のピークがこれ未満のペアは「推定できなかった」として鎖を切る。
/// ⚠ 較正は docs/SPEC.md §4。値を変えるときは scripts/restore-calibrate.sh をやり直す
pub const default_min_peak = 0.5;

/// ROI の周りの帯の差（R/G/B の差の絶対値の平均）がこれを超えるフレームからは借りない。null なら確かめない。
/// 手持ちの実写（72 ケース）で、確かめないと戻した画素の 29.8% が外れ、6 で 1.8%（圧縮だけで外れるのは最大 1.1%）。
/// 合成のパン（中央）の coverage は変わらない。⚠ 較正は docs/SPEC.md §4
pub const default_max_ring_diff: ?f64 = 6;
/// 別のフレームから借りるか（temporal.Mode、ADR 0017）
pub const default_temporal: temporal.Mode = .auto;

pub const Args = struct {
    video: []const u8 = "",
    rect: ?temporal.Rect = null,
    /// detect-roi の JSON。x / y / width / height を読む
    roi_json: ?[]const u8 = null,
    window: usize = 15,
    min_peak: f64 = default_min_peak,
    motion: MotionModel = default_motion,
    fill: spatial.Method = default_fill,
    mask: MaskMode = default_mask,
    max_ring_diff: ?f64 = default_max_ring_diff,
    temporal: temporal.Mode = default_temporal,
    /// Temporal の debug の可視化の出力先（debug_view.zig）。.mp4 なら動画、それ以外はディレクトリに連番の PNG
    debug_out: ?[]const u8 = null,
    /// RGB24 の生フレームの出力先。"-" なら標準出力（そのとき集計は標準エラーへ）。空なら書かない
    raw_out: []const u8 = "",
    /// 全フレームを H.264 の MP4 に書き出す先（mp4.zig）
    mp4_out: ?[]const u8 = null,
    crf: u8 = 18,
    audio: AudioMode = .copy,
    /// 進み具合を書くファイル（書き出しを呼ぶ GUI が読む）。`progress_every` フレームごとに
    /// "frames <済んだ数> <全体の見込み>\n" で書き直す。全体が分からなければ 0
    progress_out: ?[]const u8 = null,
    /// 推測で埋めた画素を時間方向に落ち着かせる（stabilize.zig）
    stable_fill: bool = true,
    /// マスクを使わないとき、別のフレームから借りない範囲の広げ幅（px）
    temporal_guard: u32 = default_temporal_guard,
    /// 画素ごとの由来（provenance.zig の形式、1 画素 1 バイト）の出力先
    provenance_out: ?[]const u8 = null,
    /// 隣り合うフレームの移動量の推定を 1 行ずつ書く（診断用）: "<frame> <dx> <dy> <peak>"
    shifts_out: ?[]const u8 = null,
};

/// 手元にある連続したフレーム列から、`target` を戻す（動きの推定・鎖・復元をまとめて行う）。
/// GUI のように窓を丸ごと持っている呼び出し側用。`run` は流しながら同じ部品（estimatePair）を使う
pub fn recoverInWindow(gpa: std.mem.Allocator, model: MotionModel, fill: spatial.Method, frames: []const temporal.Image, target: usize, roi: temporal.Rect, hidden: ?Hidden, min_peak: f64, topts: temporal.Options, out: []u8, prov: []provenance.Provenance) !temporal.Recovered {
    const lumas = try gpa.alloc(?motion.Luma, frames.len);
    defer gpa.free(lumas);
    @memset(lumas, null);
    defer for (lumas) |l| if (l) |ll| ll.deinit(gpa);
    if (model == .affine) for (frames, lumas) |f, *l| {
        l.* = try motion.Luma.init(gpa, .{ .width = f.width, .height = f.height, .rgb = f.rgb });
    };
    const motions = try gpa.alloc(?motion.Affine, frames.len - 1);
    defer gpa.free(motions);
    for (motions, 0..) |*m, i| m.* = (try estimatePair(gpa, model, frames[i], frames[i + 1], lumas[i], lumas[i + 1], roi, min_peak)).motion;
    const track = try temporal.Track.buildAffine(gpa, motions);
    defer track.deinit(gpa);
    const t = temporal.recoverFrame(frames, track, target, roi, temporalGuard(hidden, roi, default_temporal_guard, frames[target].width, frames[target].height), topts, out, prov, null);
    return fillAndTally(gpa, fill, hidden, t, out, frames[target].width, frames[target].height, prov, roi);
}

/// 動画全体から `mask_frames` 枚を取り、ROI の中のウォーターマークの画素を見分ける。`d` は読む位置が変わる
/// `roi` は推定する範囲（マスクの範囲）、`inner` はその中の本来の ROI（見分けられなかったときに使う）
pub fn estimateMask(gpa: std.mem.Allocator, d: *video.Decoder, roi: temporal.Rect, inner: temporal.Rect) !wmask.Estimate {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const frames = try video.sampleFrames(arena, d, mask_frames);
    const crops = try arena.alloc([]u8, frames.len);
    const row = @as(usize, roi.w) * 3;
    for (frames, crops) |f, *c| {
        c.* = try arena.alloc(u8, row * roi.h);
        for (0..roi.h) |j| @memcpy(c.*[j * row ..][0..row], f.rgb[((roi.y + j) * f.width + roi.x) * 3 ..][0..row]);
    }
    if (crops.len < 3) {
        // フレームが足りず見分けられない。ROI 全体を隠す
        const hidden = try gpa.alloc(bool, @as(usize, roi.w) * roi.h);
        @memset(hidden, false);
        for (inner.y - roi.y..inner.y - roi.y + inner.h) |y| @memset(hidden[y * roi.w + inner.x - roi.x ..][0..inner.w], true);
        return .{ .hidden = hidden, .accepted = false, .fraction = 1, .threshold = 0, .inside_mad = 0, .outside_mad = 0 };
    }
    return wmask.estimate(gpa, crops, roi.w, roi.h, .{ .inner = .{ .x = inner.x - roi.x, .y = inner.y - roi.y, .w = inner.w, .h = inner.h } });
}

/// Temporal の後に残った unrecovered を振り分けて埋め、由来を数え直す。
///
/// `hidden`（ROI の大きさ、wmask.zig）があれば、戻せなかった画素のうちウォーターマークの外のものは入力のまま
/// （original）にし、ウォーターマークの画素だけを埋める。Temporal は ROI 全体に対して行う: ウォーターマークの
/// すぐ隣の画素は圧縮でウォーターマークの色がにじんでいるので、別フレームの実画素で戻せるならそちらの方が近い
/// （合成のパンで、Temporal もマスクで絞ると SSIM 0.942 → 0.804 に下がった）
///
/// マスクの範囲（`Hidden.area`）は ROI より広いことがある（`mask_margin`）。ROI の外でマスクの内側の画素は
/// Temporal が触っていないので、戻せなかった画素として埋める。数えるのはマスクの範囲全体
fn fillAndTally(gpa: std.mem.Allocator, fill: spatial.Method, hidden: ?Hidden, t: temporal.Recovered, out: []u8, w: u32, h: u32, prov: []provenance.Provenance, roi: temporal.Rect) !temporal.Recovered {
    const area = if (hidden) |m| m.area else roi;
    if (hidden) |m| for (0..area.h) |yy| for (0..area.w) |xx| {
        const i = (area.y + yy) * w + area.x + xx;
        const hd = m.mask[yy * area.w + xx];
        if (prov[i] == .unrecovered and !hd) prov[i] = .original;
        if (prov[i] == .original and hd) prov[i] = .unrecovered;
    };
    if (fill == .none and hidden == null) return t;
    _ = try spatial.fill(gpa, fill, out, w, h, prov, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h });
    var tally: temporal.Recovered = .{};
    for (area.y..area.y + area.h) |y| for (area.x..area.x + area.w) |x| tally.add(prov[y * w + x]);
    return tally;
}

/// マスク（wmask.zig）と、それが覆う範囲（ROI を `mask_margin` 広げたもの）
pub const Hidden = struct { mask: []const bool, area: temporal.Rect };

test "fillAndTally: fills the watermark pixels outside the ROI too, and keeps the rest as input" {
    // 8 x 6 の画像、ROI は (2,2) 3 x 2、マスクの範囲は (1,1) 5 x 4。
    // マスクは ROI の中の (2,2) と、ROI の外の (1,1) と (5,4) だけ
    const gpa = std.testing.allocator;
    const w = 8;
    const h = 6;
    var rgb: [w * h * 3]u8 = undefined;
    for (0..w * h) |i| rgb[i * 3 ..][0..3].* = .{ 100, 100, 100 };
    var prov: [w * h]provenance.Provenance = undefined;
    @memset(&prov, .original);
    const roi: temporal.Rect = .{ .x = 2, .y = 2, .w = 3, .h = 2 };
    for (2..4) |y| for (2..5) |x| {
        prov[y * w + x] = .unrecovered; // Temporal で戻せなかった
    };
    const area: temporal.Rect = .{ .x = 1, .y = 1, .w = 5, .h = 4 };
    var mask = [_]bool{false} ** (5 * 4);
    mask[(2 - 1) * 5 + (2 - 1)] = true; // ROI の中 (2,2)
    mask[0] = true; // ROI の外 (1,1)
    mask[(4 - 1) * 5 + (5 - 1)] = true; // ROI の外 (5,4)
    const t = try fillAndTally(gpa, .harmonic, .{ .mask = &mask, .area = area }, .{}, &rgb, w, h, &prov, roi);
    try std.testing.expectEqual(provenance.Provenance.spatial_inpainted, prov[2 * w + 2]);
    try std.testing.expectEqual(provenance.Provenance.spatial_inpainted, prov[1 * w + 1]);
    try std.testing.expectEqual(provenance.Provenance.spatial_inpainted, prov[4 * w + 5]);
    try std.testing.expectEqual(provenance.Provenance.original, prov[2 * w + 3]); // ROI の中でマスクの外
    try std.testing.expectEqual(provenance.Provenance.original, prov[0]); // マスクの範囲の外
    // 数えるのはマスクの範囲全体（入力のまま残した画素は original として数える）
    try std.testing.expectEqual(@as(usize, 3), t.counts.get(.spatial_inpainted));
    try std.testing.expectEqual(@as(usize, 5 * 4 - 3), t.counts.get(.original));
}

const Slot = struct {
    /// 入力のストリームの time_base での時刻（書き出しに使う）
    pts: i64,
    rgb: []u8,
    /// affine のときだけ使う輝度（次のフレームとの推定に使い回す）
    luma: ?motion.Luma,
    /// 1 つ前のフレームからの動き。先頭フレームと、推定できなかったときは null
    motion: ?motion.Affine,
};

/// 隣り合うフレームの動きを 1 つ推定する。平行移動と affine の両方の入口
pub fn estimatePair(gpa: std.mem.Allocator, model: MotionModel, prev: temporal.Image, cur: temporal.Image, prev_luma: ?motion.Luma, cur_luma: ?motion.Luma, roi: temporal.Rect, min_peak: f64) !struct { motion: ?motion.Affine, shift: temporal.Shift, inliers: u32 } {
    const shift = try temporal.estimateShift(gpa, prev, cur, roi);
    switch (model) {
        .translation => return .{
            .motion = if (shift.peak >= min_peak) motion.Affine.translation(@floatFromInt(shift.dx), @floatFromInt(shift.dy)) else null,
            .shift = shift,
            .inliers = 0,
        },
        .affine => {
            // 位相相関の平行移動は、ブロックを探す中心にだけ使う。信用できなければ 0 を中心に探す
            const center: [2]i32 = if (shift.peak >= min_peak) .{ shift.dx, shift.dy } else .{ 0, 0 };
            const est = try motion.estimateAffine(gpa, prev_luma.?, cur_luma.?, .{ .x = roi.x, .y = roi.y, .w = roi.w, .h = roi.h }, center, .{});
            return .{ .motion = if (est) |e| e.motion else null, .shift = shift, .inliers = if (est) |e| e.inliers else 0 };
        },
    }
}

fn writeProgress(io: Io, path: []const u8, done: u64, total: u64) !void {
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "frames {d} {d}\n", .{ done, total });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line });
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err: *Io.Writer, args: Args) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();

    const given: temporal.Rect = args.rect orelse blk: {
        const path = args.roi_json.?;
        const data = cwd.readFileAlloc(io, path, arena, .limited(1 << 16)) catch |e| {
            try err.print("vrestore: could not read '{s}': {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        const Roi = struct { x: u32, y: u32, width: u32, height: u32 };
        const r = std.json.parseFromSliceLeaky(Roi, arena, data, .{ .ignore_unknown_fields = true }) catch {
            try err.print("vrestore: '{s}' is not a detect-roi JSON (needs x, y, width, height)\n", .{path});
            return 1;
        };
        break :blk .{ .x = r.x, .y = r.y, .w = r.width, .h = r.height };
    };

    var d = video.Decoder.open(try arena.dupeZ(u8, args.video)) catch |e| {
        try err.print("vrestore: could not open '{s}': {s}\n", .{ args.video, video.describe(e) });
        return 1;
    };
    defer d.close();
    const w = d.info.width;
    const h = d.info.height;
    if (given.w == 0 or given.h == 0 or @as(u64, given.x) + given.w > w or @as(u64, given.y) + given.h > h) {
        try err.print("vrestore: the ROI {d},{d} {d}x{d} goes outside the video ({d}x{d})\n", .{ given.x, given.y, given.w, given.h, w, h });
        return 1;
    }
    const rect = given;

    // 全体のフレーム数の見込み（進み具合の分母）。尺かフレームレートが分からなければ 0
    const expected_frames: u64 = if (d.info.duration_sec) |ds| (if (d.info.frame_rate) |fr| @intFromFloat(@round(ds * fr)) else 0) else 0;

    // 出力先
    var raw_buf: [64 * 1024]u8 = undefined;
    const want_raw = args.raw_out.len > 0;
    const to_stdout = std.mem.eql(u8, args.raw_out, "-");
    const raw_file: ?Io.File = if (to_stdout or !want_raw) null else cwd.createFile(io, args.raw_out, .{}) catch |e| {
        try err.print("vrestore: could not create '{s}': {s}\n", .{ args.raw_out, @errorName(e) });
        return 1;
    };
    defer if (raw_file) |f| f.close(io);
    var raw_w: Io.File.Writer = .initStreaming(raw_file orelse .stdout(), io, &raw_buf);
    var mp4_w: ?mp4.Writer = if (args.mp4_out) |p| mp4.Writer.open(try arena.dupeZ(u8, p), try arena.dupeZ(u8, args.video), &d, .{ .crf = args.crf, .audio = args.audio == .copy }) catch |e| {
        try err.print("vrestore: could not write '{s}': {s}\n", .{ p, mp4.describe(e) });
        return 1;
    } else null;
    defer if (mp4_w) |*m| m.close();
    const summary = if (to_stdout) err else out;
    var prov_buf: [64 * 1024]u8 = undefined;
    const prov_file: ?Io.File = if (args.provenance_out) |p| cwd.createFile(io, p, .{}) catch |e| {
        try err.print("vrestore: could not create '{s}': {s}\n", .{ p, @errorName(e) });
        return 1;
    } else null;
    defer if (prov_file) |f| f.close(io);
    var prov_w: ?Io.File.Writer = if (prov_file) |f| .initStreaming(f, io, &prov_buf) else null;

    var shifts_buf: [4096]u8 = undefined;
    const shifts_file: ?Io.File = if (args.shifts_out) |p| cwd.createFile(io, p, .{}) catch |e| {
        try err.print("vrestore: could not create '{s}': {s}\n", .{ p, @errorName(e) });
        return 1;
    } else null;
    defer if (shifts_file) |f| f.close(io);
    var shifts_w: ?Io.File.Writer = if (shifts_file) |f| .initStreaming(f, io, &shifts_buf) else null;

    // マスク: 別に開いた decoder で動画全体から取る（流す方の読む位置を変えない）
    var mask_est: ?wmask.Estimate = null;
    defer if (mask_est) |m| m.deinit(gpa);
    if (args.mask == .auto) {
        var d2 = try video.Decoder.open(try arena.dupeZ(u8, args.video));
        defer d2.close();
        mask_est = try estimateMask(gpa, &d2, maskArea(args.mask, rect, w, h), rect);
    }
    // 見分けられなかったときは ROI 全体を隠す（広げた範囲は使わない）
    // 見分けられなかったときも、ROI の中すべてと、周りの帯のはみ出した縁を隠すマスクになっている（wmask.Params.inner）
    const hidden: ?Hidden = if (mask_est) |m| .{ .mask = m.hidden, .area = maskArea(args.mask, rect, w, h) } else null;

    // 画素ごとの借りた / 借りなかった理由（JSON の集計と debug の可視化）
    const detail = try arena.alloc(temporal.Detail, @as(usize, rect.w) * rect.h);
    var n_accepted: u64 = 0;
    var n_rejected: u64 = 0;
    const debug_buf: ?[]u8 = if (args.debug_out != null) try arena.alloc(u8, @as(usize, w) * 2 * h * 3) else null;
    var debug_mp4: ?mp4.Writer = null;
    defer if (debug_mp4) |*m| m.close();
    if (args.debug_out) |p| {
        if (std.mem.endsWith(u8, p, ".mp4")) {
            debug_mp4 = mp4.Writer.open(try arena.dupeZ(u8, p), try arena.dupeZ(u8, args.video), &d, .{ .crf = 18, .audio = false, .width = w * 2, .rotation = false }) catch |e| {
                try err.print("vrestore: could not write '{s}': {s}\n", .{ p, mp4.describe(e) });
                return 1;
            };
        } else cwd.createDirPath(io, p) catch |e| {
            try err.print("vrestore: could not create '{s}': {s}\n", .{ p, @errorName(e) });
            return 1;
        };
    }
    var stable: ?stabilize.State = null;
    defer if (stable) |st| st.deinit(gpa);
    const frame_bytes = d.frameBytes();
    const out_rgb = try arena.alloc(u8, frame_bytes);
    const prov = try arena.alloc(provenance.Provenance, @as(usize, w) * h);

    // 前後 window 枚ずつを持つリングの代わりに、先頭を捨てる配列（最大 2 * window + 1 枚）
    var slots: std.ArrayList(Slot) = .empty;
    defer for (slots.items) |sl| if (sl.luma) |l| l.deinit(gpa);
    var free: std.ArrayList([]u8) = .empty; // 使い終わったバッファを再利用する
    var lo: usize = 0; // slots[0] のフレーム番号
    var next_target: usize = 0;
    var eof = false;
    var total: provenance.Tally = .{};
    var coverage_min: f64 = 1;
    var cuts: usize = 0;
    var peak_min: f64 = 1;
    var peak_max: f64 = 0;

    while (true) {
        // target + window まで読み進める
        while (!eof and lo + slots.items.len <= next_target + args.window) {
            const buf = free.pop() orelse try arena.alloc(u8, frame_bytes);
            const f = d.next(buf) catch |e| {
                try err.print("vrestore: could not decode '{s}': {s}\n", .{ args.video, video.describe(e) });
                return 1;
            } orelse {
                try free.append(arena, buf);
                eof = true;
                break;
            };
            const luma: ?motion.Luma = if (args.motion == .affine) try motion.Luma.init(gpa, .{ .width = w, .height = h, .rgb = f.rgb }) else null;
            var m: ?motion.Affine = null;
            if (slots.items.len > 0) {
                const prev = slots.items[slots.items.len - 1];
                const est = try estimatePair(gpa, args.motion, .{ .width = w, .height = h, .rgb = prev.rgb }, .{ .width = w, .height = h, .rgb = f.rgb }, prev.luma, luma, rect, args.min_peak);
                m = est.motion;
                if (m == null) cuts += 1;
                if (shifts_w) |*sw| {
                    try sw.interface.print("{d} {d} {d} {d:.4}", .{ lo + slots.items.len, est.shift.dx, est.shift.dy, est.shift.peak });
                    if (args.motion == .affine) {
                        if (m) |a| try sw.interface.print(" affine {d:.5} {d:.5} {d:.3} {d:.5} {d:.5} {d:.3} inliers {d}", .{ a.a, a.b, a.c, a.d, a.e, a.f, est.inliers }) else try sw.interface.writeAll(" affine none");
                    }
                    try sw.interface.writeAll("\n");
                }
                peak_min = @min(peak_min, est.shift.peak);
                peak_max = @max(peak_max, est.shift.peak);
            }
            try slots.append(arena, .{ .rgb = buf, .pts = f.pts, .luma = luma, .motion = m });
        }
        if (next_target >= lo + slots.items.len) break;

        // 窓の中のフレームと、隣り合うペアの移動量（フレームごとに作って捨てる。arena に積むと尺に比例して増える）
        const n = slots.items.len;
        const images = try gpa.alloc(temporal.Image, n);
        defer gpa.free(images);
        const motions = try gpa.alloc(?motion.Affine, n - 1);
        defer gpa.free(motions);
        for (slots.items, 0..) |s, i| {
            images[i] = .{ .width = w, .height = h, .rgb = s.rgb };
            if (i > 0) motions[i - 1] = s.motion;
        }
        const track = try temporal.Track.buildAffine(gpa, motions);
        defer track.deinit(gpa);
        const t_r = temporal.recoverFrame(images, track, next_target - lo, rect, temporalGuard(hidden, rect, args.temporal_guard, w, h), .{ .mode = args.temporal, .max_ring_diff = args.max_ring_diff }, out_rgb, prov, detail);
        for (detail) |dd| switch (dd.class) {
            .accepted => n_accepted += 1,
            .rejected => n_rejected += 1,
            .none => {},
        };
        const r = try fillAndTally(gpa, args.fill, hidden, t_r, out_rgb, w, h, prov, rect);
        if (args.stable_fill and args.fill != .none) {
            const area = if (hidden) |m| m.area else rect;
            if (stable == null) stable = try stabilize.State.init(gpa, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h }, w, h);
            stable.?.apply(out_rgb, images[next_target - lo].rgb, w, prov, .{});
        }
        total.merge(r);
        coverage_min = @min(coverage_min, r.coverage());

        if (args.progress_out) |pp| if ((next_target + 1) % progress_every == 0) try writeProgress(io, pp, next_target + 1, expected_frames);
        if (want_raw) try raw_w.interface.writeAll(out_rgb);
        if (mp4_w) |*m| m.write(out_rgb, slots.items[next_target - lo].pts) catch |e| {
            try err.print("vrestore: could not write '{s}': {s}\n", .{ args.mp4_out.?, mp4.describe(e) });
            return 1;
        };
        if (prov_w) |*pw| try pw.interface.writeAll(std.mem.sliceAsBytes(prov));
        if (debug_buf) |db| {
            debug_view.render(db, w, h, images[next_target - lo].rgb, out_rgb, prov, rect, if (hidden) |m| m.area else rect, detail, args.window);
            if (debug_mp4) |*m| m.write(db, slots.items[next_target - lo].pts) catch |e| {
                try err.print("vrestore: could not write '{s}': {s}\n", .{ args.debug_out.?, mp4.describe(e) });
                return 1;
            } else {
                const png = try video.encodePng(gpa, w * 2, h, db);
                defer gpa.free(png);
                var name_buf: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "frame-{d:0>6}.png", .{next_target});
                const path = try std.fs.path.join(gpa, &.{ args.debug_out.?, name });
                defer gpa.free(path);
                try cwd.writeFile(io, .{ .sub_path = path, .data = png });
            }
        }
        next_target += 1;

        // 次の target の窓から外れたフレームを捨てる
        while (lo + args.window < next_target and slots.items.len > 0) {
            const old = slots.orderedRemove(0);
            if (old.luma) |l| l.deinit(gpa);
            try free.append(arena, old.rgb);
            lo += 1;
        }
    }
    if (want_raw) try raw_w.interface.flush();
    if (args.progress_out) |pp| try writeProgress(io, pp, next_target, next_target);
    if (debug_mp4) |*m| m.finish() catch |e| {
        try err.print("vrestore: could not write '{s}': {s}\n", .{ args.debug_out.?, mp4.describe(e) });
        return 1;
    };
    if (mp4_w) |*m| m.finish() catch |e| {
        try err.print("vrestore: could not write '{s}': {s}\n", .{ args.mp4_out.?, mp4.describe(e) });
        return 1;
    };
    if (prov_w) |*pw| try pw.interface.flush();
    if (shifts_w) |*sw| try sw.interface.flush();

    if (next_target == 0) {
        try err.print("vrestore: '{s}' has no decodable frame\n", .{args.video});
        return 1;
    }
    try summary.print("{{\"frames\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"motion\":\"{s}\",\"fill\":\"{s}\",\"window\":{d},\"min_peak\":{d:.3},\"recovered\":{d},\"pixels\":{d},\"coverage\":{d:.4},\"coverage_min\":{d:.4},\"pairs_cut\":{d},\"peak_min\":{d:.3},\"peak_max\":{d:.3},\"provenance\":", .{
        next_target, rect.x, rect.y, rect.w, rect.h, @tagName(args.motion), @tagName(args.fill), args.window, args.min_peak, total.recovered(), total.roiPixels(), total.coverage(), coverage_min, cuts, peak_min, peak_max,
    });
    try total.writeJson(summary);
    try summary.print(",\"temporal\":\"{s}\",\"temporal_pixels\":{{\"accepted\":{d},\"rejected\":{d}}}", .{ @tagName(args.temporal), n_accepted, n_rejected });
    try summary.print(",\"mask\":\"{s}\"", .{@tagName(args.mask)});
    if (stable) |st| try summary.print(",\"stable_fill\":{{\"blended\":{d},\"reset\":{d}}}", .{ st.blended, st.reset });
    if (mask_est) |m| try summary.print(",\"mask_accepted\":{},\"mask_fraction\":{d:.4},\"mask_inside_mad\":{d:.2},\"mask_outside_mad\":{d:.2}", .{ m.accepted, m.fraction, m.inside_mad, m.outside_mad });
    if (mp4_w) |*m| {
        try summary.print(",\"out\":{{\"frames\":{d},\"crf\":{d},\"audio\":", .{ m.frames, args.crf });
        if (m.audioPackets()) |n| try summary.print("{{\"copied_packets\":{d}}}", .{n}) else try summary.print("\"{s}\"", .{if (args.audio == .none) "none" else "absent"});
        try summary.writeAll("}");
    }
    try summary.writeAll("}\n");
    return 0;
}
