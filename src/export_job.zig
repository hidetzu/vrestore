//! GUI から全フレームの書き出しを頼むときの、SDL に依存しない部分（docs/adr/0014）。
//!
//! 書き出しそのものは `vrestore restore --out`（CLI と同じ経路）を子プロセスで動かす。ここが持つのは:
//! - 出力するファイルの名前（元の動画の隣に `<名前>-restored.mp4`。既にあれば `-2`、`-3` … を足して上書きしない）
//! - 子プロセスに渡す引数
//! - 子プロセスが書く進み具合（`restore --progress`）の読み取りと、残り時間の見込み

const std = @import("std");

pub const Progress = struct {
    done: u64,
    /// 全体の見込み。分からなければ 0
    total: u64,

    pub fn fraction(p: Progress) ?f64 {
        if (p.total == 0) return null;
        return @min(1, @as(f64, @floatFromInt(p.done)) / @as(f64, @floatFromInt(p.total)));
    }

    /// これまでの速さが続くとしたときの残り秒数
    pub fn etaSec(p: Progress, elapsed_sec: f64) ?f64 {
        if (p.done == 0 or p.total == 0 or p.done >= p.total) return null;
        return elapsed_sec / @as(f64, @floatFromInt(p.done)) * @as(f64, @floatFromInt(p.total - p.done));
    }
};

/// "frames <done> <total>" を読む。書きかけ・壊れていれば null
pub fn parseProgress(text: []const u8) ?Progress {
    var it = std.mem.tokenizeAny(u8, text, " \n");
    const tag = it.next() orelse return null;
    if (!std.mem.eql(u8, tag, "frames")) return null;
    const done = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const total = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return .{ .done = done, .total = total };
}

pub const Paths = struct {
    mp4: []const u8,
    /// 検出した ROI（detect-roi と同じ形の JSON）。後で CLI からも同じ範囲を使える
    roi_json: []const u8,
    /// restore の集計（標準出力）
    summary_json: []const u8,
    /// restore の標準エラー
    log: []const u8,
    progress: []const u8,
};

/// `video` の隣に置く出力の名前を決める。`exists(ctx, path)` が true を返す名前は使わない
pub fn paths(gpa: std.mem.Allocator, video: []const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) !Paths {
    const dir = std.fs.path.dirname(video);
    const base = std.fs.path.basename(video);
    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
    var n: u32 = 1;
    while (true) : (n += 1) {
        const name = if (n == 1) try std.fmt.allocPrint(gpa, "{s}-restored", .{stem}) else try std.fmt.allocPrint(gpa, "{s}-restored-{d}", .{ stem, n });
        const prefix = if (dir) |d| try std.fs.path.join(gpa, &.{ d, name }) else name;
        const p = try pathsFor(gpa, prefix);
        if (exists(ctx, p.mp4)) continue;
        return p;
    }
}

/// `prefix`（拡張子なし）に .mp4 / .roi.json / .json / .log / .progress を付けた名前
pub fn pathsFor(gpa: std.mem.Allocator, prefix: []const u8) !Paths {
    return .{
        .mp4 = try std.fmt.allocPrint(gpa, "{s}.mp4", .{prefix}),
        .roi_json = try std.fmt.allocPrint(gpa, "{s}.roi.json", .{prefix}),
        .summary_json = try std.fmt.allocPrint(gpa, "{s}.json", .{prefix}),
        .log = try std.fmt.allocPrint(gpa, "{s}.log", .{prefix}),
        .progress = try std.fmt.allocPrint(gpa, "{s}.progress", .{prefix}),
    };
}

pub const Settings = struct { motion: []const u8, fill: []const u8, mask: []const u8 };

/// 子プロセスの引数（argv[0] は vrestore の実行ファイル）
pub fn restoreArgs(gpa: std.mem.Allocator, vrestore: []const u8, p: Paths, video: []const u8, s: Settings) ![]const []const u8 {
    return gpa.dupe([]const u8, &.{
        vrestore, "restore", "--roi",      p.roi_json, "--motion", s.motion, "--fill", s.fill, "--mask", s.mask,
        "--out",  p.mp4,     "--progress", p.progress, video,
    });
}

/// 秒を "h:mm:ss" か "m:ss" にする
pub fn formatDuration(buf: []u8, sec: f64) []const u8 {
    const t: u64 = @intFromFloat(@max(0, @round(sec)));
    const h = t / 3600;
    const m = t / 60 % 60;
    const s = t % 60;
    return (if (h > 0) std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) else std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s })) catch buf[0..0];
}

// ---- tests -------------------------------------------------------------------

test "export_job: reads the progress the restore writes, and ignores a half-written file" {
    try std.testing.expectEqual(Progress{ .done = 30, .total = 300 }, parseProgress("frames 30 300\n").?);
    try std.testing.expectEqual(@as(?Progress, null), parseProgress(""));
    try std.testing.expectEqual(@as(?Progress, null), parseProgress("frames 30"));
    try std.testing.expectEqual(@as(?Progress, null), parseProgress("frames x 300\n"));
    const p = parseProgress("frames 30 300\n").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), p.fraction().?, 1e-9);
    // 30 フレームに 10 秒なら、残り 270 フレームに 90 秒
    try std.testing.expectApproxEqAbs(@as(f64, 90), p.etaSec(10).?, 1e-9);
    // 全体が分からなければ割合も残り時間も出さない
    try std.testing.expectEqual(@as(?f64, null), (Progress{ .done = 30, .total = 0 }).fraction());
    try std.testing.expectEqual(@as(?f64, null), (Progress{ .done = 30, .total = 0 }).etaSec(10));
}

test "export_job: output goes next to the video and never overwrites" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Set = struct { have: []const []const u8 };
    const f = struct {
        fn f(s: Set, p: []const u8) bool {
            for (s.have) |h| if (std.mem.eql(u8, h, p)) return true;
            return false;
        }
    }.f;
    const p1 = try paths(arena, "media/a.b.mp4", Set{ .have = &.{} }, f);
    try std.testing.expectEqualStrings("media/a.b-restored.mp4", p1.mp4);
    try std.testing.expectEqualStrings("media/a.b-restored.roi.json", p1.roi_json);
    try std.testing.expectEqualStrings("media/a.b-restored.progress", p1.progress);
    const p3 = try paths(arena, "media/a.b.mp4", Set{ .have = &.{ "media/a.b-restored.mp4", "media/a.b-restored-2.mp4" } }, f);
    try std.testing.expectEqualStrings("media/a.b-restored-3.mp4", p3.mp4);
    try std.testing.expectEqualStrings("v-restored.mp4", (try paths(arena, "v", Set{ .have = &.{} }, f)).mp4);
    const args = try restoreArgs(arena, "bin/vrestore", p1, "media/a.b.mp4", .{ .motion = "affine", .fill = "harmonic", .mask = "auto" });
    try std.testing.expectEqualStrings("bin/vrestore", args[0]);
    try std.testing.expectEqualStrings("media/a.b-restored.mp4", args[11]);
    try std.testing.expectEqualStrings("media/a.b.mp4", args[args.len - 1]);
}

test "export_job: durations read as h:mm:ss" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0:05", formatDuration(&buf, 4.6));
    try std.testing.expectEqualStrings("12:34", formatDuration(&buf, 754));
    try std.testing.expectEqualStrings("3:02:01", formatDuration(&buf, 3 * 3600 + 121));
}
