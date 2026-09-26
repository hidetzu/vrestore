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

/// 位相相関のピークがこれ未満のペアは「推定できなかった」として鎖を切る。
/// ⚠ 較正は docs/SPEC.md §4。値を変えるときは scripts/restore-calibrate.sh をやり直す
pub const default_min_peak = 0.5;

/// ROI の周りの帯の差（R/G/B の差の絶対値の平均）がこれを超えるフレームからは借りない。null なら確かめない。
/// 手持ちの実写（72 ケース）で、確かめないと戻した画素の 29.8% が外れ、6 で 1.8%（圧縮だけで外れるのは最大 1.1%）。
/// 合成のパン（中央）の coverage は変わらない。⚠ 較正は docs/SPEC.md §4
pub const default_max_ring_diff: ?f64 = 6;

pub const Args = struct {
    video: []const u8 = "",
    rect: ?temporal.Rect = null,
    /// detect-roi の JSON。x / y / width / height を読む
    roi_json: ?[]const u8 = null,
    window: usize = 15,
    min_peak: f64 = default_min_peak,
    max_ring_diff: ?f64 = default_max_ring_diff,
    /// RGB24 の生フレームの出力先。"-" なら標準出力（そのとき集計は標準エラーへ）
    raw_out: []const u8 = "",
    /// 画素ごとの由来（provenance.zig の形式、1 画素 1 バイト）の出力先
    provenance_out: ?[]const u8 = null,
    /// 隣り合うフレームの移動量の推定を 1 行ずつ書く（診断用）: "<frame> <dx> <dy> <peak>"
    shifts_out: ?[]const u8 = null,
};

const Slot = struct {
    rgb: []u8,
    /// 1 つ前のフレームからの移動。先頭フレームは null
    shift: ?temporal.Shift,
};

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err: *Io.Writer, args: Args) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();

    const rect: temporal.Rect = args.rect orelse blk: {
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
    if (rect.w == 0 or rect.h == 0 or @as(u64, rect.x) + rect.w > w or @as(u64, rect.y) + rect.h > h) {
        try err.print("vrestore: the ROI {d},{d} {d}x{d} goes outside the video ({d}x{d})\n", .{ rect.x, rect.y, rect.w, rect.h, w, h });
        return 1;
    }

    // 出力先
    var raw_buf: [64 * 1024]u8 = undefined;
    const to_stdout = std.mem.eql(u8, args.raw_out, "-");
    const raw_file: ?Io.File = if (to_stdout) null else cwd.createFile(io, args.raw_out, .{}) catch |e| {
        try err.print("vrestore: could not create '{s}': {s}\n", .{ args.raw_out, @errorName(e) });
        return 1;
    };
    defer if (raw_file) |f| f.close(io);
    var raw_w: Io.File.Writer = .initStreaming(raw_file orelse .stdout(), io, &raw_buf);
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

    const frame_bytes = d.frameBytes();
    const out_rgb = try arena.alloc(u8, frame_bytes);
    const prov = try arena.alloc(provenance.Provenance, @as(usize, w) * h);

    // 前後 window 枚ずつを持つリングの代わりに、先頭を捨てる配列（最大 2 * window + 1 枚）
    var slots: std.ArrayList(Slot) = .empty;
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
            var shift: ?temporal.Shift = null;
            if (slots.items.len > 0) {
                const prev = slots.items[slots.items.len - 1].rgb;
                shift = try temporal.estimateShift(gpa, .{ .width = w, .height = h, .rgb = prev }, .{ .width = w, .height = h, .rgb = f.rgb }, rect);
                if (shift.?.peak < args.min_peak) cuts += 1;
                if (shifts_w) |*sw| try sw.interface.print("{d} {d} {d} {d:.4}\n", .{ lo + slots.items.len, shift.?.dx, shift.?.dy, shift.?.peak });
                peak_min = @min(peak_min, shift.?.peak);
                peak_max = @max(peak_max, shift.?.peak);
            }
            try slots.append(arena, .{ .rgb = buf, .shift = shift });
        }
        if (next_target >= lo + slots.items.len) break;

        // 窓の中のフレームと、隣り合うペアの移動量（フレームごとに作って捨てる。arena に積むと尺に比例して増える）
        const n = slots.items.len;
        const images = try gpa.alloc(temporal.Image, n);
        defer gpa.free(images);
        const shifts = try gpa.alloc(temporal.Shift, n - 1);
        defer gpa.free(shifts);
        for (slots.items, 0..) |s, i| {
            images[i] = .{ .width = w, .height = h, .rgb = s.rgb };
            if (i > 0) shifts[i - 1] = s.shift.?;
        }
        const track = try temporal.Track.build(gpa, shifts, args.min_peak);
        defer track.deinit(gpa);
        const r = temporal.recoverFrame(images, track, next_target - lo, rect, args.max_ring_diff, out_rgb, prov);
        total.merge(r);
        coverage_min = @min(coverage_min, r.coverage());

        try raw_w.interface.writeAll(out_rgb);
        if (prov_w) |*pw| try pw.interface.writeAll(std.mem.sliceAsBytes(prov));
        next_target += 1;

        // 次の target の窓から外れたフレームを捨てる
        while (lo + args.window < next_target and slots.items.len > 0) {
            try free.append(arena, slots.orderedRemove(0).rgb);
            lo += 1;
        }
    }
    try raw_w.interface.flush();
    if (prov_w) |*pw| try pw.interface.flush();
    if (shifts_w) |*sw| try sw.interface.flush();

    if (next_target == 0) {
        try err.print("vrestore: '{s}' has no decodable frame\n", .{args.video});
        return 1;
    }
    try summary.print("{{\"frames\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"window\":{d},\"min_peak\":{d:.3},\"recovered\":{d},\"pixels\":{d},\"coverage\":{d:.4},\"coverage_min\":{d:.4},\"pairs_cut\":{d},\"peak_min\":{d:.3},\"peak_max\":{d:.3},\"provenance\":", .{
        next_target, rect.x, rect.y, rect.w, rect.h, args.window, args.min_peak, total.recovered(), total.roiPixels(), total.coverage(), coverage_min, cuts, peak_min, peak_max,
    });
    try total.writeJson(summary);
    try summary.writeAll("}\n");
    return 0;
}
