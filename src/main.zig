const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const usage =
    \\usage: vrestore [--version] [--help]
    \\
    \\Experimental video restoration tool.
    \\No subcommands are implemented yet; ROI detection comes next (docs/SPEC.md).
    \\
;

const Command = union(enum) {
    help,
    version,
    /// 知らない引数。利用者に見せるのでそのまま持つ
    unknown: []const u8,
};

/// argv[0] を除いた引数を解釈する。引数が無ければ help。
fn parseArgs(args: []const []const u8) Command {
    if (args.len == 0) return .help;
    const a = args[0];
    if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) return .version;
    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
    return .{ .unknown = a };
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var buf: [1024]u8 = undefined;
    switch (parseArgs(args[1..])) {
        .help => {
            var w: Io.File.Writer = .init(.stdout(), io, &buf);
            try w.interface.writeAll(usage);
            try w.interface.flush();
            return 0;
        },
        .version => {
            var w: Io.File.Writer = .init(.stdout(), io, &buf);
            try w.interface.print("vrestore {s}\n", .{build_options.version});
            try w.interface.flush();
            return 0;
        },
        .unknown => |a| {
            var w: Io.File.Writer = .init(.stderr(), io, &buf);
            try w.interface.print("vrestore: unknown argument '{s}'\n\n{s}", .{ a, usage });
            try w.interface.flush();
            return 2;
        },
    }
}

test "parseArgs: no arguments shows help" {
    try std.testing.expectEqual(Command.help, parseArgs(&.{}));
}

test "parseArgs: --version and -V" {
    try std.testing.expectEqual(Command.version, parseArgs(&.{"--version"}));
    try std.testing.expectEqual(Command.version, parseArgs(&.{"-V"}));
}

test "parseArgs: unknown argument is kept verbatim" {
    const got = parseArgs(&.{"--delogo"});
    try std.testing.expectEqualStrings("--delogo", got.unknown);
}

test "version is a valid semantic version" {
    _ = try std.SemanticVersion.parse(build_options.version);
}
