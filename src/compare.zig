//! `vrestore compare`: 元の動画（正解）と処理後の動画を、矩形の中でフレームごとに比べる。
//! 復元がどれだけ元に戻せたかを測るためのもの。指標の定義は metrics.zig。

const std = @import("std");
const Io = std.Io;
const video = @import("video.zig");
const metrics = @import("metrics.zig");
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;

pub const Args = struct {
    reference: []const u8 = "",
    test_video: []const u8 = "",
    /// null なら画面全体
    rect: ?metrics.Rect = null,
    /// detect-roi の JSON。x / y / width / height を矩形にする（--rect の代わり）
    roi_json: ?[]const u8 = null,
    per_frame: bool = false,
    /// 画素ごとの由来（`vrestore restore --provenance`）。由来ごとに PSNR などを出す
    provenance: ?[]const u8 = null,
};

/// "x,y,w,h" を読む
pub fn parseRect(s: []const u8) ?metrics.Rect {
    var it = std.mem.splitScalar(u8, s, ',');
    var v: [4]u32 = undefined;
    for (&v) |*p| p.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err: *Io.Writer, args: Args) !u8 {
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
    const rect = args.rect orelse if (args.roi_json) |p| blk: {
        const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 16)) catch |e| {
            try err.print("vrestore: could not read '{s}': {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        const Roi = struct { x: u32, y: u32, width: u32, height: u32 };
        const r = std.json.parseFromSliceLeaky(Roi, arena, data, .{ .ignore_unknown_fields = true }) catch {
            try err.print("vrestore: '{s}' is not a detect-roi JSON (needs x, y, width, height)\n", .{p});
            return 1;
        };
        break :blk metrics.Rect{ .x = r.x, .y = r.y, .w = r.width, .h = r.height };
    } else metrics.Rect{ .x = 0, .y = 0, .w = ref.info.width, .h = ref.info.height };

    var prov_read_buf: [64 * 1024]u8 = undefined;
    const prov_file: ?Io.File = if (args.provenance) |p| Io.Dir.cwd().openFile(io, p, .{}) catch |e| {
        try err.print("vrestore: could not open the provenance file '{s}': {s}\n", .{ p, @errorName(e) });
        return 1;
    } else null;
    defer if (prov_file) |f| f.close(io);
    var prov_r: ?Io.File.Reader = if (prov_file) |f| .initStreaming(f, io, &prov_read_buf) else null;
    const labels = try arena.alloc(u8, @as(usize, ref.info.width) * ref.info.height);
    // 由来ごとの、画素数で重み付けした MSE の和・画素数・外れた画素の数
    var cls_sum: std.EnumArray(Provenance, f64) = .initFill(0);
    var cls_n: std.EnumArray(Provenance, usize) = .initFill(0);
    var cls_bad: std.EnumArray(Provenance, usize) = .initFill(0);
    var roi_n: usize = 0;

    const buf_a = try arena.alloc(u8, ref.frameBytes());
    const buf_b = try arena.alloc(u8, tst.frameBytes());
    var n: usize = 0;
    var ssim_sum: f64 = 0;
    var ssim_min: f64 = std.math.inf(f64);
    var mse_sum: f64 = 0;
    var bad_sum: usize = 0;
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
        if (prov_r) |*pr| {
            pr.interface.readSliceAll(labels) catch {
                try err.print("vrestore: the provenance file '{s}' ends before frame {d}; it needs one {d}x{d} byte plane per frame\n", .{ args.provenance.?, n, ref.info.width, ref.info.height });
                return 1;
            };
            for (labels) |b| if (provenance.fromByte(b) == null) {
                try err.print("vrestore: the provenance file '{s}' has an unknown value {d} in frame {d}; it may come from another version of vrestore\n", .{ args.provenance.?, b, n });
                return 1;
            };
            const ia: metrics.Image = .{ .width = fa.?.width, .height = fa.?.height, .rgb = fa.?.rgb };
            const ib: metrics.Image = .{ .width = fb.?.width, .height = fb.?.height, .rgb = fb.?.rgb };
            for (std.enums.values(Provenance)) |p| {
                const m = metrics.mseWhere(ia, ib, rect, labels, @intFromEnum(p)) catch unreachable;
                cls_sum.getPtr(p).* += m.mse * @as(f64, @floatFromInt(m.pixels));
                cls_n.getPtr(p).* += m.pixels;
                cls_bad.getPtr(p).* += m.bad;
            }
            roi_n += @as(usize, rect.w) * rect.h;
        }
        bad_sum += metrics.badPixels(.{ .width = fa.?.width, .height = fa.?.height, .rgb = fa.?.rgb }, .{ .width = fb.?.width, .height = fb.?.height, .rgb = fb.?.rgb }, rect) catch unreachable;
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
    // 矩形の中で、どれかの色で正解から bad_pixel_error より離れた画素の割合（由来によらない）
    try out.print(",\"bad_fraction\":{d:.4}", .{@as(f64, @floatFromInt(bad_sum)) / (nf * @as(f64, @floatFromInt(@as(usize, rect.w) * rect.h)))});
    if (args.provenance != null) {
        // 戻せた由来（Provenance.isRecovered）をまとめたもの
        var masked_sum: f64 = 0;
        var masked_n: usize = 0;
        var masked_bad: usize = 0;
        for (std.enums.values(Provenance)) |p| if (p.isRecovered()) {
            masked_sum += cls_sum.get(p);
            masked_n += cls_n.get(p);
            masked_bad += cls_bad.get(p);
        };
        // マスクのある画素（戻した画素）だけの PSNR と、それが矩形の何割か
        try out.print(",\"masked_pixels\":{d},\"masked_fraction\":{d:.4},\"masked_psnr\":", .{ masked_n, @as(f64, @floatFromInt(masked_n)) / @as(f64, @floatFromInt(@max(1, roi_n))) });
        const p = if (masked_n == 0) null else metrics.psnr(masked_sum / @as(f64, @floatFromInt(masked_n)));
        if (p) |v| try out.print("{d:.3}", .{v}) else try out.writeAll("null");
        // 戻した画素のうち、どれかの色で正解から bad_pixel_error より離れた画素の割合
        try out.print(",\"masked_bad_fraction\":{d:.4}", .{@as(f64, @floatFromInt(masked_bad)) / @as(f64, @floatFromInt(@max(1, masked_n)))});
        // 由来ごと（矩形の中にあったものだけ）
        try out.writeAll(",\"provenance\":{");
        var first = true;
        for (std.enums.values(Provenance)) |cls| {
            const pn = cls_n.get(cls);
            if (pn == 0) continue;
            if (!first) try out.writeAll(",");
            first = false;
            try out.print("\"{s}\":{{\"pixels\":{d},\"fraction\":{d:.4},\"psnr\":", .{ @tagName(cls), pn, @as(f64, @floatFromInt(pn)) / @as(f64, @floatFromInt(@max(1, roi_n))) });
            if (metrics.psnr(cls_sum.get(cls) / @as(f64, @floatFromInt(pn)))) |v| try out.print("{d:.3}", .{v}) else try out.writeAll("null");
            try out.print(",\"bad_fraction\":{d:.4}}}", .{@as(f64, @floatFromInt(cls_bad.get(cls))) / @as(f64, @floatFromInt(pn))});
        }
        try out.writeAll("}");
    }
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
