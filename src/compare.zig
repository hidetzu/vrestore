//! `vrestore compare`: 元の動画（正解）と処理後の動画を、矩形の中でフレームごとに比べる。
//! 復元がどれだけ元に戻せたかを測るためのもの。指標の定義は metrics.zig。

const std = @import("std");
const Io = std.Io;
const video = @import("video.zig");
const metrics = @import("metrics.zig");

pub const Args = struct {
    reference: []const u8 = "",
    test_video: []const u8 = "",
    /// null なら画面全体
    rect: ?metrics.Rect = null,
    per_frame: bool = false,
};

/// "x,y,w,h" を読む
pub fn parseRect(s: []const u8) ?metrics.Rect {
    var it = std.mem.splitScalar(u8, s, ',');
    var v: [4]u32 = undefined;
    for (&v) |*p| p.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

pub fn run(gpa: std.mem.Allocator, out: *Io.Writer, err: *Io.Writer, args: Args) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ref = video.Decoder.open(try arena.dupeZ(u8, args.reference)) catch |e| {
        try err.print("vrestore: could not open '{s}': {s}\n", .{ args.reference, video.describe(e) });
        return 1;
    };
    defer ref.close();
    var tst = video.Decoder.open(try arena.dupeZ(u8, args.test_video)) catch |e| {
        try err.print("vrestore: could not open '{s}': {s}\n", .{ args.test_video, video.describe(e) });
        return 1;
    };
    defer tst.close();

    if (ref.info.width != tst.info.width or ref.info.height != tst.info.height) {
        try err.print("vrestore: the videos have different sizes ({d}x{d} and {d}x{d}); compare needs the same frames\n", .{ ref.info.width, ref.info.height, tst.info.width, tst.info.height });
        return 1;
    }
    const rect = args.rect orelse metrics.Rect{ .x = 0, .y = 0, .w = ref.info.width, .h = ref.info.height };

    const buf_a = try arena.alloc(u8, ref.frameBytes());
    const buf_b = try arena.alloc(u8, tst.frameBytes());
    var n: usize = 0;
    var ssim_sum: f64 = 0;
    var ssim_min: f64 = std.math.inf(f64);
    var mse_sum: f64 = 0;
    while (true) {
        const fa = ref.next(buf_a) catch |e| return decodeFailed(err, args.reference, e);
        const fb = tst.next(buf_b) catch |e| return decodeFailed(err, args.test_video, e);
        if (fa == null and fb == null) break;
        if (fa == null or fb == null) {
            // 片方だけ終わった。1 フレームずれた比較は無意味なので、黙って短い方に合わせない
            const longer = if (fa == null) args.test_video else args.reference;
            try err.print("vrestore: the videos have different frame counts: '{s}' has more than {d} frames; compare needs the same frames\n", .{ longer, n });
            return 1;
        }
        n += 1;
        const s = metrics.score(
            .{ .width = fa.?.width, .height = fa.?.height, .rgb = fa.?.rgb },
            .{ .width = fb.?.width, .height = fb.?.height, .rgb = fb.?.rgb },
            rect,
        ) catch |e| {
            try err.print("vrestore: bad --rect {d},{d},{d},{d} for {d}x{d}: {s}\n", .{ rect.x, rect.y, rect.w, rect.h, ref.info.width, ref.info.height, switch (e) {
                error.RectOutside => "it goes outside the frame",
                error.RectTooSmall => "each side needs at least 8 px",
                error.SizeMismatch => unreachable,
            } });
            return 2;
        };
        ssim_sum += s.ssimAll();
        ssim_min = @min(ssim_min, s.ssimAll());
        mse_sum += s.mseAvg();
        if (args.per_frame) {
            try out.print("{{\"n\":{d},\"ssim\":[{d:.6},{d:.6},{d:.6}],\"ssim_all\":{d:.6},\"mse\":[{d:.4},{d:.4},{d:.4}],\"mse_avg\":{d:.4}}}\n", .{
                n, s.ssim[0], s.ssim[1], s.ssim[2], s.ssimAll(), s.mse[0], s.mse[1], s.mse[2], s.mseAvg(),
            });
        }
    }
    if (n == 0) {
        try err.print("vrestore: '{s}' has no decodable frame\n", .{args.reference});
        return 1;
    }
    const nf: f64 = @floatFromInt(n);
    // PSNR はフレーム平均の MSE から出す（FFmpeg の psnr フィルタの average と同じ）
    try out.print("{{\"frames\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"ssim\":{d:.6},\"ssim_min\":{d:.6},\"mse\":{d:.4},\"psnr\":", .{
        n, rect.x, rect.y, rect.w, rect.h, ssim_sum / nf, ssim_min, mse_sum / nf,
    });
    if (metrics.psnr(mse_sum / nf)) |p| try out.print("{d:.3}", .{p}) else try out.writeAll("null");
    try out.writeAll("}\n");
    return 0;
}

fn decodeFailed(err: *Io.Writer, path: []const u8, e: video.Error) !u8 {
    try err.print("vrestore: could not decode '{s}': {s}\n", .{ path, video.describe(e) });
    return 1;
}

test "compare: parseRect" {
    try std.testing.expectEqual(metrics.Rect{ .x = 1, .y = 2, .w = 30, .h = 40 }, parseRect("1,2,30,40").?);
    try std.testing.expectEqual(@as(?metrics.Rect, null), parseRect("1,2,30"));
    try std.testing.expectEqual(@as(?metrics.Rect, null), parseRect("1,2,30,40,5"));
    try std.testing.expectEqual(@as(?metrics.Rect, null), parseRect("1,2,-3,4"));
}
