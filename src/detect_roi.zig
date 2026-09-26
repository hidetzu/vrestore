//! `vrestore detect-roi`: 動画と参照画像から ROI を検出し、JSON とデバッグ画像を出す。
//! 検出そのものは roi.zig、動画と画像の読み書きは video.zig。ここはその配線だけ。

const std = @import("std");
const Io = std.Io;
const video = @import("video.zig");
const roi = @import("roi.zig");

/// reliable の既定の閾値。
/// ⚠ 較正の記録は docs/SPEC.md §4。値を変えるときは較正をやり直し、そこも更新する
pub const default_thresholds: roi.Thresholds = .{
    .min_confidence = 0.4,
    .min_margin = 0.08,
    .min_psr = 0,
};

pub const Args = struct {
    video: []const u8 = "",
    reference: []const u8 = "",
    frames: usize = 15,
    debug_dir: ?[]const u8 = null,
    thresholds: roi.Thresholds = default_thresholds,
};

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err: *Io.Writer, args: Args) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ref_path = try arena.dupeZ(u8, args.reference);
    const ref = video.loadImage(arena, ref_path) catch |e| {
        try err.print("vrestore: could not read the reference image '{s}': {s}\n", .{ args.reference, video.describe(e) });
        return 1;
    };

    const video_path = try arena.dupeZ(u8, args.video);
    var d = video.Decoder.open(video_path) catch |e| {
        try err.print("vrestore: could not open '{s}': {s}\n", .{ args.video, video.describe(e) });
        return 1;
    };
    defer d.close();

    const refimg: roi.Image = .{ .width = ref.width, .height = ref.height, .rgb = ref.rgb };
    const result = detectInVideo(arena, gpa, &d, refimg, args.frames, args.thresholds) catch |e| {
        try err.writeAll("vrestore: ");
        try describeProblem(err, e, refimg, d.info);
        try err.writeAll("\n");
        return 1;
    };
    const det = result.detection;
    const frames = result.frames;

    var json: Io.Writer.Allocating = .init(arena);
    try writeJson(&json.writer, det);
    try out.writeAll(json.written());

    if (!det.reliable) {
        try err.writeAll("vrestore: the detection is not reliable:");
        var it = det.reasons.iterator();
        while (it.next()) |r| try err.print("\n  - {s}", .{explain(r)});
        try err.writeAll("\n  Cutting the reference larger, with the whole watermark and some margin, often helps.\n");
    }

    if (args.debug_dir) |dir| {
        writeDebug(arena, io, dir, frames[0], det, json.written()) catch |e| {
            try err.print("vrestore: could not write the debug files to '{s}': {s}\n", .{ dir, @errorName(e) });
            return 1;
        };
        try err.print("vrestore: wrote {s}/detection.json, frame-overlay.png, roi-crop.png\n", .{dir});
    }
    return 0;
}

pub const InVideoError = error{
    ReferenceLargerThanVideo,
    ReferenceTooSmall,
    /// 参照画像に輪郭が無い
    FlatReference,
    NoDecodableFrame,
} || video.Error;

pub const InVideo = struct {
    detection: roi.Detection,
    /// 投票に使ったフレーム（`arena` の所有）。デバッグ画像は先頭を使う
    frames: []video.Frame,
};

/// 動画 `d` から等間隔に `n` 枚取り出し、参照画像 `ref` の固定位置を探す。
/// CLI（`run`）と GUI の共通の入口。GUI はここを呼ぶだけで、検出のロジックを持たない
pub fn detectInVideo(arena: std.mem.Allocator, gpa: std.mem.Allocator, d: *video.Decoder, ref: roi.Image, n: usize, th: roi.Thresholds) InVideoError!InVideo {
    if (ref.width > d.info.width or ref.height > d.info.height) return error.ReferenceLargerThanVideo;
    if (ref.width < roi.min_template_side or ref.height < roi.min_template_side) return error.ReferenceTooSmall;

    const frames = try video.sampleFrames(arena, d, n);
    if (frames.len == 0) return error.NoDecodableFrame;
    const images = try arena.alloc(roi.Image, frames.len);
    for (frames, images) |f, *img| img.* = .{ .width = f.width, .height = f.height, .rgb = f.rgb };
    const det = roi.detect(gpa, images, ref, th) catch |e| return switch (e) {
        error.FlatTemplate => error.FlatReference,
        // 大きさは上で確かめているので、ここに来るのは内部の誤り
        error.TemplateLargerThanImage, error.TemplateTooSmall, error.NoFrames => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
    return .{ .detection = det, .frames = frames };
}

/// `detectInVideo` の失敗を、利用者が次に何をすればよいか分かる文にする
pub fn describeProblem(w: *Io.Writer, e: InVideoError, ref: roi.Image, info: video.Info) Io.Writer.Error!void {
    switch (e) {
        error.ReferenceLargerThanVideo => try w.print("the reference ({d}x{d}) is larger than the video ({d}x{d}). Cut it from a frame of this video.", .{ ref.width, ref.height, info.width, info.height }),
        error.ReferenceTooSmall => try w.print("the reference ({d}x{d}) is too small; each side needs at least {d} px. Cut it larger, with some margin around the watermark.", .{ ref.width, ref.height, roi.min_template_side }),
        error.FlatReference => try w.writeAll("the reference has no edges to match (it is a flat color). Cut a region that contains the watermark."),
        error.NoDecodableFrame => try w.writeAll("the video has no decodable frame"),
        else => |ve| try w.print("could not decode the video: {s}", .{video.describe(@errorCast(ve))}),
    }
}

pub fn explain(r: roi.Reason) []const u8 {
    return switch (r) {
        .low_confidence => "the frames disagree on the position (vote ratio below --min-confidence)",
        .low_margin => "another place matches almost as well (margin below --min-margin)",
        .low_psr => "the peak does not stand out from the rest (PSR below --min-psr)",
        .unmeasured_margin => "the reference is (almost) as large as the video, so no other position could be compared",
    };
}

/// JSON 1 行。数値の桁は固定して、差分や比較をしやすくする
pub fn writeJson(w: *Io.Writer, d: roi.Detection) Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"confidence\":{d:.3},\"psr\":", .{ d.x, d.y, d.width, d.height, d.confidence });
    if (d.psr) |v| try w.print("{d:.1}", .{v}) else try w.writeAll("null");
    try w.writeAll(",\"margin\":");
    if (d.margin) |v| try w.print("{d:.3}", .{v}) else try w.writeAll("null");
    try w.print(",\"peak\":{d:.3},\"frames_voted\":{d},\"reliable\":{},\"reasons\":[", .{ d.peak, d.frames_voted, d.reliable });
    var it = d.reasons.iterator();
    var first = true;
    while (it.next()) |r| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"{s}\"", .{@tagName(r)});
    }
    try w.writeAll("]}\n");
}

fn writeDebug(arena: std.mem.Allocator, io: Io, dir: []const u8, frame: video.Frame, det: roi.Detection, json: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "detection.json" }), .data = json });

    // 検出矩形を重ねた元フレーム。当たっていれば赤、reliable=false なら黄色にして、画像だけで判断できるようにする
    const overlay = try arena.dupe(u8, frame.rgb);
    const color: [3]u8 = if (det.reliable) .{ 255, 32, 32 } else .{ 255, 210, 0 };
    drawRect(overlay, frame.width, frame.height, det, color, 2);
    const overlay_png = try video.encodePng(arena, frame.width, frame.height, overlay);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "frame-overlay.png" }), .data = overlay_png });

    const crop = try cropRgb(arena, frame, det);
    const crop_png = try video.encodePng(arena, @intCast(det.width), @intCast(det.height), crop);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "roi-crop.png" }), .data = crop_png });
}

/// 矩形の外側に `thick` px の枠を描く。内側は元の画素のまま残す（枠でウォーターマークを隠さない）
fn drawRect(rgb: []u8, w: u32, h: u32, d: roi.Detection, color: [3]u8, thick: usize) void {
    const x0: i64 = @intCast(d.x);
    const y0: i64 = @intCast(d.y);
    const x1: i64 = x0 + @as(i64, @intCast(d.width)) - 1;
    const y1: i64 = y0 + @as(i64, @intCast(d.height)) - 1;
    const t: i64 = @intCast(thick);
    var y = y0 - t;
    while (y <= y1 + t) : (y += 1) {
        var x = x0 - t;
        while (x <= x1 + t) : (x += 1) {
            const inside = x >= x0 and x <= x1 and y >= y0 and y <= y1;
            if (inside or x < 0 or y < 0 or x >= w or y >= h) continue;
            const i = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 3;
            rgb[i..][0..3].* = color;
        }
    }
}

fn cropRgb(arena: std.mem.Allocator, f: video.Frame, d: roi.Detection) ![]u8 {
    const row = d.width * 3;
    const out = try arena.alloc(u8, row * d.height);
    for (0..d.height) |j| {
        const src = ((d.y + j) * f.width + d.x) * 3;
        @memcpy(out[j * row ..][0..row], f.rgb[src..][0..row]);
    }
    return out;
}

test "detect_roi: writeJson" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var reasons: std.EnumSet(roi.Reason) = .initEmpty();
    try writeJson(&w, .{ .x = 493, .y = 5, .width = 142, .height = 77, .confidence = 1, .psr = 19.54, .margin = 0.4123, .peak = 0.87, .frames_voted = 15, .reliable = true, .reasons = reasons });
    try std.testing.expectEqualStrings(
        \\{"x":493,"y":5,"width":142,"height":77,"confidence":1.000,"psr":19.5,"margin":0.412,"peak":0.870,"frames_voted":15,"reliable":true,"reasons":[]}
        \\
    , w.buffered());

    reasons.insert(.low_margin);
    reasons.insert(.low_confidence);
    w = .fixed(&buf);
    try writeJson(&w, .{ .x = 0, .y = 0, .width = 20, .height = 20, .confidence = 0.2, .psr = 3, .margin = 0.01, .peak = 0.3, .frames_voted = 5, .reliable = false, .reasons = reasons });
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\"reliable\":false,\"reasons\":[\"low_confidence\",\"low_margin\"]}\n"));

    // 測れなかった値は JSON の null にする（inf は JSON ではない）
    w = .fixed(&buf);
    try writeJson(&w, .{ .x = 0, .y = 0, .width = 20, .height = 20, .confidence = 1, .psr = null, .margin = null, .peak = 0.5, .frames_voted = 1, .reliable = false, .reasons = .initOne(.unmeasured_margin) });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"psr\":null,\"margin\":null,") != null);
}

test "detect_roi: drawRect leaves the inside untouched and clips at the edges" {
    var rgb = [_]u8{0} ** (6 * 5 * 3);
    // (0,0) 3x2 の矩形。枠の左と上は画面外に出る
    drawRect(&rgb, 6, 5, .{ .x = 0, .y = 0, .width = 3, .height = 2, .confidence = 0, .psr = 0, .margin = 0, .peak = 0, .frames_voted = 0, .reliable = true, .reasons = .initEmpty() }, .{ 9, 9, 9 }, 1);
    const at = struct {
        fn f(buf: []const u8, x: usize, y: usize) u8 {
            return buf[(y * 6 + x) * 3];
        }
    }.f;
    try std.testing.expectEqual(@as(u8, 0), at(&rgb, 0, 0)); // 内側
    try std.testing.expectEqual(@as(u8, 0), at(&rgb, 2, 1)); // 内側の右下
    try std.testing.expectEqual(@as(u8, 9), at(&rgb, 3, 0)); // 右の枠
    try std.testing.expectEqual(@as(u8, 9), at(&rgb, 3, 2)); // 右下の角
    try std.testing.expectEqual(@as(u8, 9), at(&rgb, 0, 2)); // 下の枠
    try std.testing.expectEqual(@as(u8, 0), at(&rgb, 4, 0)); // 枠の外
}
