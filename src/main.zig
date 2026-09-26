const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const video = @import("video.zig");
const roi = @import("roi.zig");
const detect_roi = @import("detect_roi.zig");
const compare = @import("compare.zig");
const restore_cmd = @import("restore_cmd.zig");

const usage =
    \\usage: vrestore <command> [args]
    \\
    \\Experimental video restoration tool.
    \\
    \\commands:
    \\  probe <video>
    \\      print width, height, duration and codec as JSON, after decoding the first frame
    \\
    \\  detect-roi --ref <image> [options] <video>
    \\      find where the watermark cut out in <image> is fixed in <video>, print JSON.
    \\      Cut the reference generously: include the whole watermark and some margin.
    \\      --frames <n>            frames to vote with, spread over the video (default 15)
    \\      --debug-dir <dir>       also write detection.json, frame-overlay.png, roi-crop.png
    \\      --min-confidence <f>    reliable needs vote ratio >= f
    \\      --min-margin <f>        reliable needs (peak - best elsewhere) >= f
    \\      --min-psr <f>           reliable needs PSR >= f (0 = not used)
    \\
    \\  restore (--roi <detection.json> | --rect x,y,w,h) --raw <out.rgb|-> [options] <video>
    \\      put back the pixels hidden by the watermark, taken from frames where the background
    \\      moved out from under it (Temporal Recovery, translation only). Writes RGB24 raw frames;
    \\      pixels it could not recover are left as they were. Prints the recovery coverage as JSON.
    \\      --window <n>        frames to look at on each side (default 15)
    \\      --motion <m>        translation (whole-frame shift) or affine (shift + rotation + zoom)
    \\      --mask <m>          none (hide the whole ROI) or auto (hide only the watermark's own pixels,
    \\                          found as those that stay the same across the video)
    \\      --fill <f>          none, directional or harmonic: guess the pixels still unrecovered from
    \\                          their surroundings (provenance spatial_inpainted; not counted in coverage)
    \\      --provenance <out>  also write where each pixel came from, 1 byte per pixel per frame:
    \\                          0 = outside the ROI, 1 = unrecovered, 2 = temporal_real, 4 = spatial_inpainted
    \\
    \\  compare [--rect x,y,w,h | --roi <detection.json>] [--per-frame] [--provenance <file>] <reference> <test>
    \\      compare <test> with the original <reference> frame by frame, inside the rect
    \\      (default: whole frame). Prints SSIM and PSNR as JSON; both videos need the same frames.
    \\      With --provenance (from restore), also PSNR and bad pixels per provenance
    \\      (unrecovered / temporal_real), and over the recovered pixels together (masked_*).
    \\
    \\  --version       print the version
    \\  --help          print this message
    \\
;

const Command = union(enum) {
    help,
    version,
    probe: []const u8,
    detect_roi: detect_roi.Args,
    compare: compare.Args,
    restore: restore_cmd.Args,
    /// 引数が足りない。どのコマンドかを持つ
    missing_arg: []const u8,
    /// 引数の形が違う。利用者に見せる文と、問題の引数
    bad_arg: struct { why: []const u8, arg: []const u8 },
    /// 知らない引数。利用者に見せるのでそのまま持つ
    unknown: []const u8,
};

/// argv[0] を除いた引数を解釈する。引数が無ければ help。
fn parseArgs(args: []const []const u8) Command {
    if (args.len == 0) return .help;
    const a = args[0];
    if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) return .version;
    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
    if (std.mem.eql(u8, a, "probe")) {
        if (args.len < 2) return .{ .missing_arg = a };
        return .{ .probe = args[1] };
    }
    if (std.mem.eql(u8, a, "detect-roi")) return parseDetectRoi(args[1..]);
    if (std.mem.eql(u8, a, "compare")) return parseCompare(args[1..]);
    if (std.mem.eql(u8, a, "restore")) return parseRestore(args[1..]);
    return .{ .unknown = a };
}

fn parseDetectRoi(args: []const []const u8) Command {
    var out: detect_roi.Args = .{};
    var video_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            if (video_path != null) return .{ .bad_arg = .{ .why = "only one video can be given", .arg = a } };
            video_path = a;
            continue;
        }
        if (i + 1 >= args.len) return .{ .bad_arg = .{ .why = "option needs a value", .arg = a } };
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--ref")) {
            out.reference = v;
        } else if (std.mem.eql(u8, a, "--debug-dir")) {
            out.debug_dir = v;
        } else if (std.mem.eql(u8, a, "--frames")) {
            out.frames = std.fmt.parseInt(usize, v, 10) catch
                return .{ .bad_arg = .{ .why = "--frames needs a positive integer", .arg = v } };
            if (out.frames == 0) return .{ .bad_arg = .{ .why = "--frames needs a positive integer", .arg = v } };
        } else if (std.mem.eql(u8, a, "--min-confidence")) {
            out.thresholds.min_confidence = parseFraction(v) orelse
                return .{ .bad_arg = .{ .why = "--min-confidence needs a number between 0 and 1", .arg = v } };
        } else if (std.mem.eql(u8, a, "--min-margin")) {
            out.thresholds.min_margin = parseFraction(v) orelse
                return .{ .bad_arg = .{ .why = "--min-margin needs a number between 0 and 1", .arg = v } };
        } else if (std.mem.eql(u8, a, "--min-psr")) {
            out.thresholds.min_psr = std.fmt.parseFloat(f64, v) catch
                return .{ .bad_arg = .{ .why = "--min-psr needs a number", .arg = v } };
        } else {
            return .{ .unknown = a };
        }
    }
    if (out.reference.len == 0) return .{ .bad_arg = .{ .why = "detect-roi needs --ref <image>", .arg = "--ref" } };
    out.video = video_path orelse return .{ .missing_arg = "detect-roi" };
    return .{ .detect_roi = out };
}

fn parseCompare(args: []const []const u8) Command {
    var out: compare.Args = .{};
    var paths: [2][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--per-frame")) {
            out.per_frame = true;
        } else if (std.mem.eql(u8, a, "--provenance")) {
            if (i + 1 >= args.len) return .{ .bad_arg = .{ .why = "option needs a value", .arg = a } };
            i += 1;
            out.provenance = args[i];
        } else if (std.mem.eql(u8, a, "--roi")) {
            if (i + 1 >= args.len) return .{ .bad_arg = .{ .why = "option needs a value", .arg = a } };
            i += 1;
            out.roi_json = args[i];
        } else if (std.mem.eql(u8, a, "--rect")) {
            if (i + 1 >= args.len) return .{ .bad_arg = .{ .why = "option needs a value", .arg = a } };
            i += 1;
            out.rect = compare.parseRect(args[i]) orelse
                return .{ .bad_arg = .{ .why = "--rect needs x,y,w,h", .arg = args[i] } };
        } else if (std.mem.startsWith(u8, a, "--")) {
            return .{ .unknown = a };
        } else {
            if (n == 2) return .{ .bad_arg = .{ .why = "compare takes two videos", .arg = a } };
            paths[n] = a;
            n += 1;
        }
    }
    if (n < 2) return .{ .missing_arg = "compare" };
    out.reference = paths[0];
    out.test_video = paths[1];
    return .{ .compare = out };
}

fn parseRestore(args: []const []const u8) Command {
    var out: restore_cmd.Args = .{};
    var video_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            if (video_path != null) return .{ .bad_arg = .{ .why = "only one video can be given", .arg = a } };
            video_path = a;
            continue;
        }
        if (i + 1 >= args.len) return .{ .bad_arg = .{ .why = "option needs a value", .arg = a } };
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--roi")) {
            out.roi_json = v;
        } else if (std.mem.eql(u8, a, "--rect")) {
            const r = compare.parseRect(v) orelse return .{ .bad_arg = .{ .why = "--rect needs x,y,w,h", .arg = v } };
            out.rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        } else if (std.mem.eql(u8, a, "--raw")) {
            out.raw_out = v;
        } else if (std.mem.eql(u8, a, "--provenance")) {
            out.provenance_out = v;
        } else if (std.mem.eql(u8, a, "--shifts")) {
            out.shifts_out = v;
        } else if (std.mem.eql(u8, a, "--window")) {
            out.window = std.fmt.parseInt(usize, v, 10) catch 0;
            if (out.window == 0) return .{ .bad_arg = .{ .why = "--window needs a positive integer", .arg = v } };
        } else if (std.mem.eql(u8, a, "--mask")) {
            out.mask = std.meta.stringToEnum(restore_cmd.MaskMode, v) orelse return .{ .bad_arg = .{ .why = "--mask needs none or auto", .arg = v } };
        } else if (std.mem.eql(u8, a, "--fill")) {
            out.fill = std.meta.stringToEnum(@import("spatial.zig").Method, v) orelse return .{ .bad_arg = .{ .why = "--fill needs none, directional or harmonic", .arg = v } };
        } else if (std.mem.eql(u8, a, "--motion")) {
            out.motion = std.meta.stringToEnum(restore_cmd.MotionModel, v) orelse return .{ .bad_arg = .{ .why = "--motion needs translation or affine", .arg = v } };
        } else if (std.mem.eql(u8, a, "--max-ring-diff")) {
            out.max_ring_diff = if (std.mem.eql(u8, v, "off")) null else std.fmt.parseFloat(f64, v) catch return .{ .bad_arg = .{ .why = "--max-ring-diff needs a number or off", .arg = v } };
        } else if (std.mem.eql(u8, a, "--min-peak")) {
            out.min_peak = parseFraction(v) orelse return .{ .bad_arg = .{ .why = "--min-peak needs a number between 0 and 1", .arg = v } };
        } else {
            return .{ .unknown = a };
        }
    }
    if (out.rect == null and out.roi_json == null) return .{ .bad_arg = .{ .why = "restore needs --roi <detection.json> or --rect x,y,w,h", .arg = "--roi" } };
    if (out.raw_out.len == 0) return .{ .bad_arg = .{ .why = "restore needs --raw <out.rgb> (or - for stdout)", .arg = "--raw" } };
    out.video = video_path orelse return .{ .missing_arg = "restore" };
    return .{ .restore = out };
}

fn parseFraction(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, s) catch return null;
    return if (v >= 0 and v <= 1) v else null;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    // FFmpeg 自身のログは内部の言葉なので出さない。失敗は describe() の文で伝える
    video.c.av_log_set_level(video.c.AV_LOG_QUIET);

    var out_buf: [1024]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    defer out.interface.flush() catch {};
    defer err.interface.flush() catch {};

    switch (parseArgs(args[1..])) {
        .help => {
            try out.interface.writeAll(usage);
            return 0;
        },
        .version => {
            try out.interface.print("vrestore {s}\n", .{build_options.version});
            return 0;
        },
        .probe => |path| return probe(arena, &out.interface, &err.interface, path),
        .detect_roi => |a| return detect_roi.run(init.gpa, io, &out.interface, &err.interface, a),
        .compare => |a| return compare.run(init.gpa, io, &out.interface, &err.interface, a),
        .restore => |a| return restore_cmd.run(init.gpa, io, &out.interface, &err.interface, a),
        .bad_arg => |b| {
            try err.interface.print("vrestore: {s}: '{s}'\n\n{s}", .{ b.why, b.arg, usage });
            return 2;
        },
        .missing_arg => |cmd| {
            try err.interface.print("vrestore: '{s}' needs {s}\n\n{s}", .{ cmd, if (std.mem.eql(u8, cmd, "compare")) "two videos" else "a video file", usage });
            return 2;
        },
        .unknown => |a| {
            try err.interface.print("vrestore: unknown argument '{s}'\n\n{s}", .{ a, usage });
            return 2;
        },
    }
}

fn probe(arena: std.mem.Allocator, out: *Io.Writer, err: *Io.Writer, path: []const u8) !u8 {
    const path_z = try arena.dupeZ(u8, path);
    var d = video.Decoder.open(path_z) catch |e| {
        try err.print("vrestore: could not open '{s}': {s}\n", .{ path, video.describe(e) });
        return 1;
    };
    defer d.close();

    // コンテナのヘッダが読めてもデコードできるとは限らないので、1 フレーム目まで確かめる
    const buf = try arena.alloc(u8, d.frameBytes());
    const first = d.next(buf) catch |e| {
        try err.print("vrestore: could not decode '{s}': {s}\n", .{ path, video.describe(e) });
        return 1;
    };
    if (first == null) {
        try err.print("vrestore: '{s}' has a video stream but no decodable frame\n", .{path});
        return 1;
    }

    try out.print("{{\"width\":{d},\"height\":{d},\"duration_sec\":", .{ d.info.width, d.info.height });
    if (d.info.duration_sec) |s| try out.print("{d:.3}", .{s}) else try out.writeAll("null");
    try out.print(",\"codec\":\"{s}\"}}\n", .{d.info.codec_name});
    return 0;
}

test {
    _ = video;
    _ = roi;
    _ = detect_roi;
    _ = compare;
    _ = @import("metrics.zig");
    _ = @import("gui_state.zig");
    _ = @import("player_state.zig");
    _ = @import("glyphs.zig");
    _ = @import("fonts.zig");
    _ = @import("wmask.zig");
    _ = @import("temporal.zig");
    _ = @import("provenance.zig");
    _ = @import("motion.zig");
    _ = @import("spatial.zig");
    _ = restore_cmd;
}

test "parseArgs: no arguments shows help" {
    try std.testing.expectEqual(Command.help, parseArgs(&.{}));
}

test "parseArgs: --version and -V" {
    try std.testing.expectEqual(Command.version, parseArgs(&.{"--version"}));
    try std.testing.expectEqual(Command.version, parseArgs(&.{"-V"}));
}

test "parseArgs: probe takes a path" {
    try std.testing.expectEqualStrings("a.mp4", parseArgs(&.{ "probe", "a.mp4" }).probe);
    try std.testing.expectEqualStrings("probe", parseArgs(&.{"probe"}).missing_arg);
}

test "parseArgs: detect-roi" {
    const got = parseArgs(&.{ "detect-roi", "--ref", "r.png", "--frames", "7", "--debug-dir", "d", "v.mp4" }).detect_roi;
    try std.testing.expectEqualStrings("r.png", got.reference);
    try std.testing.expectEqualStrings("v.mp4", got.video);
    try std.testing.expectEqualStrings("d", got.debug_dir.?);
    try std.testing.expectEqual(@as(usize, 7), got.frames);

    try std.testing.expectEqualStrings("--ref", parseArgs(&.{ "detect-roi", "v.mp4" }).bad_arg.arg);
    try std.testing.expectEqualStrings("0", parseArgs(&.{ "detect-roi", "--ref", "r", "--frames", "0", "v" }).bad_arg.arg);
    try std.testing.expectEqualStrings("1.5", parseArgs(&.{ "detect-roi", "--ref", "r", "--min-margin", "1.5", "v" }).bad_arg.arg);
    try std.testing.expectEqualStrings("detect-roi", parseArgs(&.{ "detect-roi", "--ref", "r" }).missing_arg);
}

test "parseArgs: compare" {
    const got = parseArgs(&.{ "compare", "--rect", "1,2,30,40", "--per-frame", "ref.mp4", "out.mp4" }).compare;
    try std.testing.expectEqualStrings("ref.mp4", got.reference);
    try std.testing.expectEqualStrings("out.mp4", got.test_video);
    try std.testing.expectEqual(@as(u32, 30), got.rect.?.w);
    try std.testing.expect(got.per_frame);
    try std.testing.expectEqualStrings("compare", parseArgs(&.{ "compare", "a.mp4" }).missing_arg);
    try std.testing.expectEqualStrings("1,2", parseArgs(&.{ "compare", "--rect", "1,2", "a", "b" }).bad_arg.arg);
}

test "parseArgs: restore" {
    const got = parseArgs(&.{ "restore", "--roi", "d.json", "--raw", "o.rgb", "--window", "8", "v.mp4" }).restore;
    try std.testing.expectEqualStrings("d.json", got.roi_json.?);
    try std.testing.expectEqualStrings("o.rgb", got.raw_out);
    try std.testing.expectEqual(@as(usize, 8), got.window);
    try std.testing.expectEqualStrings("v.mp4", got.video);
    try std.testing.expectEqualStrings("--roi", parseArgs(&.{ "restore", "--raw", "o", "v" }).bad_arg.arg);
    try std.testing.expectEqualStrings("--raw", parseArgs(&.{ "restore", "--rect", "1,2,30,40", "v" }).bad_arg.arg);
}

test "parseArgs: unknown argument is kept verbatim" {
    const got = parseArgs(&.{"--delogo"});
    try std.testing.expectEqualStrings("--delogo", got.unknown);
}

test "version is a valid semantic version" {
    _ = try std.SemanticVersion.parse(build_options.version);
}
