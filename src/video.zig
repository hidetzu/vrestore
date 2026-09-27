//! 動画からフレームを RGB24 で取り出す。demux / decode / seek / 色変換は FFmpeg (libav*) に任せる
//! (docs/adr/0001)。ここが持つのは「どのフレームを取り出すか」だけ。

const std = @import("std");

pub const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("errno.h");
});

// AVERROR() / FFERRTAG() は関数形式のマクロで translate-c を通らないので、libavutil/error.h の定義どおりに組み立てる
pub const averror_eagain: c_int = -@as(c_int, c.EAGAIN);
pub const averror_eof = fferrtag('E', 'O', 'F', ' ');
const averror_stream_not_found = fferrtag(0xF8, 'S', 'T', 'R');

fn fferrtag(a: u8, b: u8, d: u8, e: u8) c_int {
    const tag = @as(u32, a) | @as(u32, b) << 8 | @as(u32, d) << 16 | @as(u32, e) << 24;
    return -@as(c_int, @bitCast(tag));
}

pub const Error = error{
    /// ファイルが開けない、またはコンテナとして読めない
    OpenFailed,
    /// 映像ストリームが無い
    NoVideoStream,
    /// この FFmpeg にデコーダが無い
    UnsupportedCodec,
    DecodeFailed,
    SeekFailed,
    OutOfMemory,
};

/// 利用者が次に何をすればよいか分かる言葉にする
pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.OpenFailed => "not a readable video file (missing, no permission, or unknown format)",
        error.NoVideoStream => "the file has no video stream",
        error.UnsupportedCodec => "this FFmpeg build has no decoder for the video codec",
        error.DecodeFailed => "the video stream could not be decoded",
        error.SeekFailed => "seeking in the file failed",
        error.OutOfMemory => "out of memory",
    };
}

pub const Info = struct {
    width: u32,
    height: u32,
    /// コンテナから尺が取れないとき（fragmented MP4 など）は null
    duration_sec: ?f64,
    /// 平均フレームレート。コンテナが持っていなければ null
    frame_rate: ?f64,
    codec_name: []const u8,
};

/// RGB24 で詰めた 1 フレーム（行の間に余白なし）。
pub const Frame = struct {
    width: u32,
    height: u32,
    rgb: []u8,
    /// 動画内の時刻（秒）。ストリームの開始時刻を 0 とする
    time_sec: f64,
    /// ストリームの time_base での時刻（デコーダの best_effort_timestamp）。分からなければ AV_NOPTS_VALUE。
    /// 書き出すとき（mp4.zig）に元の時刻をそのまま使う
    pts: i64 = c.AV_NOPTS_VALUE,

    pub fn pixel(f: Frame, x: u32, y: u32) [3]u8 {
        const i = (@as(usize, y) * f.width + x) * 3;
        return f.rgb[i..][0..3].*;
    }
};

pub const Decoder = struct {
    fmt: *c.AVFormatContext,
    codec: *c.AVCodecContext,
    stream: *c.AVStream,
    packet: *c.AVPacket,
    frame: *c.AVFrame,
    sws: ?*c.SwsContext = null,
    /// seek 後、この pts より前のフレームは読み捨てる（キーフレームからデコードし直すため）
    skip_before_pts: ?i64 = null,
    /// demux が終わってデコーダに flush を送った
    draining: bool = false,
    info: Info,

    pub fn open(path: [:0]const u8) Error!Decoder {
        var fmt_opt: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt_opt, path.ptr, null, null) < 0) return error.OpenFailed;
        var fmt = fmt_opt.?;
        errdefer c.avformat_close_input(@ptrCast(&fmt));
        if (c.avformat_find_stream_info(fmt, null) < 0) return error.OpenFailed;

        var dec: ?*const c.AVCodec = null;
        const idx = c.av_find_best_stream(fmt, c.AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
        if (idx == averror_stream_not_found) return error.NoVideoStream;
        if (idx < 0 or dec == null) return error.UnsupportedCodec;
        const stream: *c.AVStream = fmt.streams[@intCast(idx)];

        var codec: ?*c.AVCodecContext = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(&codec);
        if (c.avcodec_parameters_to_context(codec, stream.codecpar) < 0) return error.DecodeFailed;
        if (c.avcodec_open2(codec, dec, null) < 0) return error.UnsupportedCodec;

        var packet: ?*c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
        errdefer c.av_packet_free(&packet);
        const frame: *c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;

        const duration_sec: ?f64 = if (fmt.duration > 0)
            @as(f64, @floatFromInt(fmt.duration)) / c.AV_TIME_BASE
        else
            null;

        return .{
            .fmt = fmt,
            .codec = codec.?,
            .stream = stream,
            .packet = packet.?,
            .frame = frame,
            .info = .{
                .width = @intCast(stream.codecpar.*.width),
                .height = @intCast(stream.codecpar.*.height),
                .duration_sec = duration_sec,
                .frame_rate = if (stream.avg_frame_rate.num > 0 and stream.avg_frame_rate.den > 0)
                    @as(f64, @floatFromInt(stream.avg_frame_rate.num)) / @as(f64, @floatFromInt(stream.avg_frame_rate.den))
                else
                    null,
                .codec_name = std.mem.span(dec.?.name),
            },
        };
    }

    pub fn close(d: *Decoder) void {
        if (d.sws) |s| c.sws_freeContext(s);
        var frame: ?*c.AVFrame = d.frame;
        c.av_frame_free(&frame);
        var packet: ?*c.AVPacket = d.packet;
        c.av_packet_free(&packet);
        var codec: ?*c.AVCodecContext = d.codec;
        c.avcodec_free_context(&codec);
        var fmt: ?*c.AVFormatContext = d.fmt;
        c.avformat_close_input(&fmt);
        d.* = undefined;
    }

    /// 1 フレームに要るバイト数。`next` に渡すバッファはこの長さにする
    pub fn frameBytes(d: *const Decoder) usize {
        return @as(usize, d.info.width) * d.info.height * 3;
    }

    /// 次のフレームを `rgb`（長さ `frameBytes()`）へ書く。終端なら null。
    pub fn next(d: *Decoder, rgb: []u8) Error!?Frame {
        std.debug.assert(rgb.len == d.frameBytes());
        while (true) {
            const r = c.avcodec_receive_frame(d.codec, d.frame);
            if (r == 0) {
                defer c.av_frame_unref(d.frame);
                const pts = d.frame.best_effort_timestamp;
                if (d.skip_before_pts) |target| {
                    if (pts != c.AV_NOPTS_VALUE and pts < target) continue;
                    d.skip_before_pts = null;
                }
                try d.toRgb(rgb);
                return .{
                    .width = d.info.width,
                    .height = d.info.height,
                    .rgb = rgb,
                    .time_sec = d.ptsToSec(pts),
                    .pts = pts,
                };
            }
            if (r == averror_eof) return null;
            if (r != averror_eagain) return error.DecodeFailed;

            // デコーダがもっと入力を欲しがっている
            if (d.draining) return null;
            if (!try d.sendNextPacket()) {
                d.draining = true;
                if (c.avcodec_send_packet(d.codec, null) < 0) return error.DecodeFailed;
            }
        }
    }

    /// `sec` 以降で最初のフレームが次の `next` で出るようにする。
    /// 直前のキーフレームへ戻ってデコードし直し、`sec` より前のフレームは読み捨てる。
    pub fn seek(d: *Decoder, sec: f64) Error!void {
        const tb = d.stream.time_base;
        var target: i64 = @intFromFloat(@round(sec * @as(f64, @floatFromInt(tb.den)) / @as(f64, @floatFromInt(tb.num))));
        if (d.stream.start_time != c.AV_NOPTS_VALUE) target += d.stream.start_time;
        if (c.av_seek_frame(d.fmt, d.stream.index, target, c.AVSEEK_FLAG_BACKWARD) < 0) return error.SeekFailed;
        c.avcodec_flush_buffers(d.codec);
        d.draining = false;
        d.skip_before_pts = target;
    }

    fn sendNextPacket(d: *Decoder) Error!bool {
        while (true) {
            const r = c.av_read_frame(d.fmt, d.packet);
            if (r == averror_eof) return false;
            if (r < 0) return error.DecodeFailed;
            defer c.av_packet_unref(d.packet);
            if (d.packet.stream_index != d.stream.index) continue;
            // 壊れたパケット 1 つで全体を止めない。デコーダが拒んだものは飛ばす
            const s = c.avcodec_send_packet(d.codec, d.packet);
            if (s < 0 and s != averror_eagain) continue;
            return true;
        }
    }

    fn toRgb(d: *Decoder, rgb: []u8) Error!void {
        const f = d.frame;
        // 途中で解像度が変わる入力は SPEC の対象外。サイズが違えば取り出せないとして扱う
        if (f.width != d.info.width or f.height != d.info.height) return error.DecodeFailed;
        d.sws = c.sws_getCachedContext(
            d.sws,
            f.width,
            f.height,
            f.format,
            f.width,
            f.height,
            c.AV_PIX_FMT_RGB24,
            c.SWS_BILINEAR | c.SWS_ACCURATE_RND,
            null,
            null,
            null,
        ) orelse return error.DecodeFailed;
        var dst = [4][*c]u8{ rgb.ptr, null, null, null };
        const stride = [4]c_int{ f.width * 3, 0, 0, 0 };
        if (c.sws_scale(d.sws, &f.data, &f.linesize, 0, f.height, &dst, &stride) != f.height)
            return error.DecodeFailed;
    }

    fn ptsToSec(d: *const Decoder, pts: i64) f64 {
        if (pts == c.AV_NOPTS_VALUE) return 0;
        var p = pts;
        if (d.stream.start_time != c.AV_NOPTS_VALUE) p -= d.stream.start_time;
        const tb = d.stream.time_base;
        return @as(f64, @floatFromInt(p)) * @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den));
    }
};

/// 動画全体から最大 `n` 枚を等間隔に取り出す。
///
/// ウォーターマークの位置は固定という前提なので全フレームは要らない。ただし先頭付近に偏らせると、
/// 背景が変わらないぶん誤検出に気付けない。尺が取れないときは先頭から連続で取る。
/// 返すフレームの `rgb` は `gpa` で確保したもの。`freeFrames` で解放する。
pub fn sampleFrames(gpa: std.mem.Allocator, d: *Decoder, n: usize) Error![]Frame {
    var out: std.ArrayList(Frame) = .empty;
    errdefer freeFrames(gpa, out.items);
    try out.ensureTotalCapacity(gpa, n);

    const duration = d.info.duration_sec;
    for (0..n) |i| {
        if (duration) |dur| {
            // 末尾ぎりぎりは尺の誤差で空振りするので少し内側に寄せる
            const t = dur * 0.98 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            try d.seek(t);
        }
        const buf = try gpa.alloc(u8, d.frameBytes());
        const f = d.next(buf) catch |e| {
            gpa.free(buf);
            return e;
        } orelse {
            gpa.free(buf);
            if (duration == null) break;
            continue;
        };
        out.appendAssumeCapacity(f);
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeFrames(gpa: std.mem.Allocator, frames: []const Frame) void {
    for (frames) |f| gpa.free(f.rgb);
    gpa.free(frames);
}

pub const EncodeError = error{ UnsupportedCodec, EncodeFailed, OutOfMemory };

/// RGB24 の画像を PNG にエンコードする（FFmpeg の png エンコーダ）。返すバイト列は `gpa` の所有。
pub fn encodePng(gpa: std.mem.Allocator, width: u32, height: u32, rgb: []const u8) EncodeError![]u8 {
    std.debug.assert(rgb.len == @as(usize, width) * height * 3);
    const enc = c.avcodec_find_encoder(c.AV_CODEC_ID_PNG) orelse return error.UnsupportedCodec;
    var ctx: ?*c.AVCodecContext = c.avcodec_alloc_context3(enc) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&ctx);
    ctx.?.width = @intCast(width);
    ctx.?.height = @intCast(height);
    ctx.?.pix_fmt = c.AV_PIX_FMT_RGB24;
    ctx.?.time_base = .{ .num = 1, .den = 1 };
    if (c.avcodec_open2(ctx, enc, null) < 0) return error.EncodeFailed;

    var frame: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);
    const f = frame.?;
    f.format = c.AV_PIX_FMT_RGB24;
    f.width = @intCast(width);
    f.height = @intCast(height);
    if (c.av_frame_get_buffer(f, 0) < 0) return error.OutOfMemory;
    const row = @as(usize, width) * 3;
    for (0..height) |y| {
        const dst: [*]u8 = @ptrCast(f.data[0]);
        @memcpy(dst[y * @as(usize, @intCast(f.linesize[0])) ..][0..row], rgb[y * row ..][0..row]);
    }

    var packet: ?*c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&packet);
    if (c.avcodec_send_frame(ctx, f) < 0) return error.EncodeFailed;
    if (c.avcodec_send_frame(ctx, null) < 0) return error.EncodeFailed;
    if (c.avcodec_receive_packet(ctx, packet) < 0) return error.EncodeFailed;
    defer c.av_packet_unref(packet);
    return gpa.dupe(u8, packet.?.data[0..@intCast(packet.?.size)]);
}

/// 画像ファイル（PNG / JPEG など FFmpeg が読めるもの）を 1 枚読んで RGB24 にする。
/// 返す Frame の `rgb` は `gpa` の所有。
pub fn loadImage(gpa: std.mem.Allocator, path: [:0]const u8) Error!Frame {
    var d = try Decoder.open(path);
    defer d.close();
    const buf = try gpa.alloc(u8, d.frameBytes());
    errdefer gpa.free(buf);
    return (try d.next(buf)) orelse error.DecodeFailed;
}

// ---- tests -------------------------------------------------------------------
//
// fixture は build.zig が ffmpeg コマンドで合成する（リポジトリに動画を置かない）。
// 64x48, 10 fps, 1 秒, libx264 -qp 0, yuv420p, GOP 5。
// フレーム k は全画素が灰色 16 + 20k。yuv420p → rgb24 の往復で ±1 ずれることを
// ffmpeg 8.1.1 で観測したので、許容差は 2 とする。

const fixtures = @import("fixtures");
// build_options のパスは []const u8 なので、C に渡せる 0 終端に直す
const steps_mp4 = std.fmt.comptimePrint("{s}", .{fixtures.steps});
const not_video = std.fmt.comptimePrint("{s}", .{fixtures.not_video});
const tolerance = 2;

fn expectGray(f: Frame, want: u8) !void {
    for ([_][2]u32{ .{ 0, 0 }, .{ 63, 0 }, .{ 32, 24 }, .{ 0, 47 }, .{ 63, 47 } }) |p| {
        for (f.pixel(p[0], p[1])) |v| {
            if (@abs(@as(i16, v) - want) > tolerance) {
                std.debug.print("pixel ({d},{d}) = {d}, want {d}±{d} (t={d:.3})\n", .{ p[0], p[1], v, want, tolerance, f.time_sec });
                return error.TestExpectedEqual;
            }
        }
    }
}

fn stepGray(k: usize) u8 {
    return @intCast(16 + 20 * k);
}

test "video: open reports size, duration, frame rate and codec" {
    var d = try Decoder.open(steps_mp4);
    defer d.close();
    try std.testing.expectEqual(@as(u32, 64), d.info.width);
    try std.testing.expectEqual(@as(u32, 48), d.info.height);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), d.info.duration_sec.?, 0.05);
    try std.testing.expectEqualStrings("h264", d.info.codec_name);
    try std.testing.expectApproxEqAbs(@as(f64, 10), d.info.frame_rate.?, 1e-9);
}

test "video: next decodes every frame in order, then reports the end" {
    var d = try Decoder.open(steps_mp4);
    defer d.close();
    const buf = try std.testing.allocator.alloc(u8, d.frameBytes());
    defer std.testing.allocator.free(buf);
    var k: usize = 0;
    while (try d.next(buf)) |f| : (k += 1) {
        try expectGray(f, stepGray(k));
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(k)) * 0.1, f.time_sec, 1e-6);
    }
    try std.testing.expectEqual(@as(usize, 10), k);
    try std.testing.expectEqual(@as(?Frame, null), try d.next(buf));
}

test "video: seek lands on the exact frame, including non-keyframes" {
    var d = try Decoder.open(steps_mp4);
    defer d.close();
    const buf = try std.testing.allocator.alloc(u8, d.frameBytes());
    defer std.testing.allocator.free(buf);
    // GOP 5 なのでキーフレームは 0, 5。7 と 3 はキーフレームからデコードし直す必要がある。
    // 後ろ → 前の順も入れて、seek が前方向にしか効かない実装を落とす
    for ([_]usize{ 7, 3, 5, 0, 9 }) |k| {
        try d.seek(@as(f64, @floatFromInt(k)) * 0.1);
        const f = (try d.next(buf)).?;
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(k)) * 0.1, f.time_sec, 1e-6);
        try expectGray(f, stepGray(k));
    }
}

test "video: sampleFrames spreads over the whole duration" {
    var d = try Decoder.open(steps_mp4);
    defer d.close();
    const frames = try sampleFrames(std.testing.allocator, &d, 5);
    defer freeFrames(std.testing.allocator, frames);
    try std.testing.expectEqual(@as(usize, 5), frames.len);
    // 0.98 * i / 5 秒 → 0, 0.196, 0.392, 0.588, 0.784 → 以降で最初のフレームは 0, 2, 4, 6, 8
    for (frames, [_]usize{ 0, 2, 4, 6, 8 }) |f, k| try expectGray(f, stepGray(k));
}

test "video: encodePng then loadImage round-trips the pixels exactly" {
    const gpa = std.testing.allocator;
    var rgb: [5 * 3 * 3]u8 = undefined;
    for (&rgb, 0..) |*v, i| v.* = @intCast(i * 5);
    const png = try encodePng(gpa, 5, 3, &rgb);
    defer gpa.free(png);
    try std.testing.expectEqualSlices(u8, "\x89PNG", png[0..4]);

    // loadImage はファイルから読むので、一時ディレクトリへ書く
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.png", .data = png });
    const path = try std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}/a.png", .{tmp.sub_path}, 0);
    defer gpa.free(path);
    const img = try loadImage(gpa, path);
    defer gpa.free(img.rgb);
    try std.testing.expectEqual(@as(u32, 5), img.width);
    try std.testing.expectEqual(@as(u32, 3), img.height);
    try std.testing.expectEqualSlices(u8, &rgb, img.rgb);
}

test "video: a file that is not a video fails to open" {
    c.av_log_set_level(c.AV_LOG_QUIET);
    try std.testing.expectError(error.OpenFailed, Decoder.open(not_video));
}
