const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run only tests whose name contains this") orelse &.{};

    // バージョンは build.zig.zon だけが持つ。コードには build_options 経由で渡す
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe_mod = createRootModule(b, target, optimize, options);
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

    // ---- テスト用の動画 ----------------------------------------------------
    // リポジトリに動画を置かないので、テストのたびに ffmpeg コマンドで合成する（CLAUDE.md §4）。
    // 生成物は zig のキャッシュに入り、引数が変わらなければ作り直さない
    const steps_mp4 = synthStepsVideo(b);
    const not_video = b.addWriteFiles().add("not-video.mp4", "this is not a video\n");

    const fixtures = b.addOptions();
    fixtures.addOptionPath("steps", steps_mp4);
    fixtures.addOptionPath("not_video", not_video);

    const test_mod = createRootModule(b, target, optimize, options);
    test_mod.addOptions("fixtures", fixtures);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

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
    const cli_probe = b.addRunArtifact(exe);
    cli_probe.setName("cli_probe");
    cli_probe.addArg("probe");
    cli_probe.addFileArg(steps_mp4);
    cli_probe.expectStdOutEqual(
        \\{"width":64,"height":48,"duration_sec":1.000,"codec":"h264"}
        \\
    );
    cli_probe.expectExitCode(0);
    const cli_probe_bad = b.addRunArtifact(exe);
    cli_probe_bad.setName("cli_probe_bad");
    cli_probe_bad.addArg("probe");
    cli_probe_bad.addFileArg(not_video);
    cli_probe_bad.expectStdErrMatch("could not open");
    cli_probe_bad.expectExitCode(1);
    // stdout が他の出力と共有された通常ファイルのとき、前の出力を上書きしないこと。
    // Run ステップの stdout はパイプなので、上の cli_* ではこれが見えない（CLAUDE.md §7）
    const cli_stdout_file = b.addSystemCommand(&.{
        "sh", "-c",
        \\out="$1.txt"; { echo before; "$0" --version; echo after; } > "$out"; cat "$out"
        ,
    });
    cli_stdout_file.setName("cli_stdout_file");
    cli_stdout_file.addArtifactArg(exe);
    _ = cli_stdout_file.addOutputFileArg("stdout-file");
    cli_stdout_file.expectStdOutEqual(b.fmt("before\nvrestore {s}\nafter\n", .{zon.version}));
    if (test_filters.len == 0) {
        test_step.dependOn(&cli_stdout_file.step);
        test_step.dependOn(&cli_version.step);
        test_step.dependOn(&cli_unknown.step);
        test_step.dependOn(&cli_probe.step);
        test_step.dependOn(&cli_probe_bad.step);
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

fn createRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    // FFmpeg は pkg-config で見つける（docs/adr/0001）
    for ([_][]const u8{ "libavformat", "libavcodec", "libswscale", "libavutil" }) |lib| {
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    }
    return mod;
}

/// 64x48, 10 fps, 1 秒。フレーム k は全画素が灰色 16 + 20k。
/// 画素値でフレーム番号が分かるので、seek が正しいフレームに着いたかを判定できる。
/// -qp 0 は圧縮による画素の揺れを除くため、-g 5 はキーフレームでない位置への seek を作るため
fn synthStepsVideo(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "ffmpeg",   "-hide_banner", "-loglevel", "error",                                                        "-y",
        "-f",       "lavfi",        "-i",        "color=c=black:s=64x48:r=10:d=1,format=gray,geq=lum='16+20*N'", "-c:v",
        "libx264",  "-qp",          "0",         "-g",                                                           "5",
        "-pix_fmt", "yuv420p",
    });
    cmd.setName("synth steps.mp4");
    return cmd.addOutputFileArg("steps.mp4");
}
