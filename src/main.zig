const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const video = @import("video.zig");

const usage =
    \\usage: vrestore <command> [args]
    \\
    \\Experimental video restoration tool.
    \\
    \\commands:
    \\  probe <video>   print width, height, duration and codec as JSON,
    \\                  after decoding the first frame
    \\
    \\  --version       print the version
    \\  --help          print this message
    \\
    \\ROI detection comes next (docs/SPEC.md).
    \\
;

const Command = union(enum) {
    help,
    version,
    probe: []const u8,
    /// 引数が足りない。どのコマンドかを持つ
    missing_arg: []const u8,
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
    return .{ .unknown = a };
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
        .missing_arg => |cmd| {
            try err.interface.print("vrestore: '{s}' needs a video file\n\n{s}", .{ cmd, usage });
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
        try err.print("vrestore: could not open '{s}': {s}\n", .{ path, describe(e) });
        return 1;
    };
    defer d.close();

    // コンテナのヘッダが読めてもデコードできるとは限らないので、1 フレーム目まで確かめる
    const buf = try arena.alloc(u8, d.frameBytes());
    const first = d.next(buf) catch |e| {
        try err.print("vrestore: could not decode '{s}': {s}\n", .{ path, describe(e) });
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

/// 利用者が次に何をすればよいか分かる言葉にする
fn describe(e: video.Error) []const u8 {
    return switch (e) {
        error.OpenFailed => "not a readable video file (missing, no permission, or unknown format)",
        error.NoVideoStream => "the file has no video stream",
        error.UnsupportedCodec => "this FFmpeg build has no decoder for the video codec",
        error.DecodeFailed => "the video stream could not be decoded",
        error.SeekFailed => "seeking in the file failed",
        error.OutOfMemory => "out of memory",
    };
}

test {
    _ = video;
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

test "parseArgs: unknown argument is kept verbatim" {
    const got = parseArgs(&.{"--delogo"});
    try std.testing.expectEqualStrings("--delogo", got.unknown);
}

test "version is a valid semantic version" {
    _ = try std.SemanticVersion.parse(build_options.version);
}
