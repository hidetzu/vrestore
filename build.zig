const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run only tests whose name contains this") orelse &.{};

    // バージョンは build.zig.zon だけが持つ。コードには build_options 経由で渡す
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "vrestore",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run vrestore");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = test_filters,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // 実行ファイルを外から叩いて出力を確かめる（ユニットテストでは main の配線が見えない）
    const cli_version = b.addRunArtifact(exe);
    cli_version.setName("cli_version");
    cli_version.addArg("--version");
    cli_version.expectStdOutEqual(b.fmt("vrestore {s}\n", .{zon.version}));
    cli_version.expectExitCode(0);
    const cli_unknown = b.addRunArtifact(exe);
    cli_unknown.setName("cli_unknown");
    cli_unknown.addArg("--no-such-flag");
    cli_unknown.expectStdErrMatch("vrestore: unknown argument '--no-such-flag'");
    cli_unknown.expectExitCode(2);
    if (test_filters.len == 0) {
        test_step.dependOn(&cli_version.step);
        test_step.dependOn(&cli_unknown.step);
    }

    // check: 変更が壊れていないと言うために回すものの全部。
    // 何を回すかはここだけが持つ（.claude/skills/verify/SKILL.md と CI はここを呼ぶ）
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .check = true,
    });
    const no_media = b.addSystemCommand(&.{"scripts/check-no-media.sh"});
    // git の状態を見るので、毎回実行する（キャッシュさせない）
    no_media.has_side_effects = true;

    const check_step = b.step("check", "fmt --check, test, no-media, build");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(test_step);
    check_step.dependOn(&no_media.step);
    check_step.dependOn(b.getInstallStep());
}
