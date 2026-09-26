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
    const cli_detect_bad_ref = b.addRunArtifact(exe);
    cli_detect_bad_ref.setName("cli_detect_bad_ref");
    cli_detect_bad_ref.addArgs(&.{ "detect-roi", "--ref" });
    cli_detect_bad_ref.addFileArg(not_video);
    cli_detect_bad_ref.addFileArg(steps_mp4);
    cli_detect_bad_ref.expectStdErrMatch("could not read the reference image");
    cli_detect_bad_ref.expectExitCode(1);
    // steps.mp4 のフレームは全画素が同じ灰色で、輪郭が無い。参照に使えないと言って止まること
    const cli_detect_flat_ref = b.addRunArtifact(exe);
    cli_detect_flat_ref.setName("cli_detect_flat_ref");
    cli_detect_flat_ref.addArgs(&.{ "detect-roi", "--frames", "3", "--ref" });
    cli_detect_flat_ref.addFileArg(steps_mp4);
    cli_detect_flat_ref.addFileArg(steps_mp4);
    cli_detect_flat_ref.expectStdErrMatch("has no edges to match");
    cli_detect_flat_ref.expectExitCode(1);
    if (test_filters.len == 0) {
        test_step.dependOn(&cli_detect_bad_ref.step);
        test_step.dependOn(&cli_detect_flat_ref.step);
        test_step.dependOn(&cli_stdout_file.step);
        test_step.dependOn(&cli_version.step);
        test_step.dependOn(&cli_unknown.step);
        test_step.dependOn(&cli_probe.step);
        test_step.dependOn(&cli_probe_bad.step);
    }

    // ---- ROI 検出の合成 E2E ------------------------------------------------
    // 既知の位置にウォーターマークを焼いた動画を合成 → yuv420p でエンコード → そのフレームから参照画像を切る
    // → vrestore detect-roi → 正解と dx / dy / IoU / reliable を照合する（docs/SPEC.md §2-1）
    const video_mod = b.createModule(.{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    linkFfmpeg(video_mod);
    const roi_mod = b.createModule(.{
        .root_source_file = b.path("src/roi.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/roi_fixture.zig"),
        .target = target,
        // 画素を 1 つずつ描くので Debug だと遅い
        .optimize = .ReleaseSafe,
        .imports = &.{ .{ .name = "video", .module = video_mod }, .{ .name = "roi", .module = roi_mod } },
    });
    const tool = b.addExecutable(.{ .name = "roi_fixture", .root_module = tool_mod });
    // scripts/roi-calibrate.sh が使う
    const tools_step = b.step("tools", "Install tools/roi_fixture next to vrestore");
    tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
    tools_step.dependOn(b.getInstallStep());
    const tool_tests = b.addRunArtifact(b.addTest(.{ .root_module = tool_mod, .filters = test_filters }));
    test_step.dependOn(&tool_tests.step);

    const e2e_step = b.step("e2e", "ROI detection on synthetic videos, checked against the known position");
    for (roi_cases) |c| e2e_step.dependOn(roiCase(b, tool, exe, c));

    // check: 変更が壊れていないと言うために回すものの全部。
    // 何を回すかはここだけが持つ（.claude/skills/verify/SKILL.md と CI はここを呼ぶ）
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "tools" },
        .check = true,
    });
    const no_media = b.addSystemCommand(&.{"scripts/check-no-media.sh"});
    // git の状態を見るので、毎回実行する（キャッシュさせない）
    no_media.has_side_effects = true;

    const check_step = b.step("check", "fmt --check, test, e2e, no-media, build");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(test_step);
    check_step.dependOn(e2e_step);
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
    linkFfmpeg(mod);
    return mod;
}

/// FFmpeg は pkg-config で見つける（docs/adr/0001）
fn linkFfmpeg(mod: *std.Build.Module) void {
    for ([_][]const u8{ "libavformat", "libavcodec", "libswscale", "libavutil" }) |lib| {
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    }
}

const RoiCase = struct {
    /// tools/roi_fixture.zig の Case（key=value のカンマ区切り）。name は必須
    spec: []const u8,
    crf: u32,
};

/// CI で回す ROI の合成ケース。どれも較正（scripts/roi-calibrate.sh、docs/SPEC.md §4）で
/// 判定の境界から余裕があったものを選んでいる。境界ぎりぎりのケースは ffmpeg / x264 の版差で揺れる
const roi_cases = [_]RoiCase{
    .{ .spec = "name=pan-full,bg=pan", .crf = 16 },
    .{ .spec = "name=pan-faint-crf35,bg=pan,opacity=0.35", .crf = 35 },
    .{ .spec = "name=cut-full,bg=cut,opacity=0.6", .crf = 23 },
    .{ .spec = "name=flat-full,bg=flat", .crf = 23 },
    .{ .spec = "name=pan-tight,bg=pan,margin=0", .crf = 23 },
    .{ .spec = "name=pan-part,bg=pan,ref=part,part_chars=3,margin=2", .crf = 23 },
    // 繰り返す文字列の途中を 1 周期だけ切る。得票率も PSR も高いのに別の行に当たる（較正で dy=18 を観測）。
    // PSR 単独で reliable を決めない理由で、reliable=false でなければならない
    .{ .spec = "name=repeat-mid,bg=flat,period=3,ref=part,part_chars=3,part_offset=3,margin=0,expect=safe", .crf = 16 },
    // ウォーターマークの無い動画から切った参照。背景が動くので、どこにも固定されていない
    .{ .spec = "name=absent,bg=pan,opacity=0,expect=reject", .crf = 23 },
};

fn roiCase(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile, c: RoiCase) *std.Build.Step {
    const spec = b.fmt("{s},crf={d}", .{ c.spec, c.crf });
    const name = spec[5..std.mem.indexOfScalar(u8, spec, ',').?];

    const synth = b.addRunArtifact(tool);
    synth.setName(b.fmt("roi synth {s}", .{name}));
    synth.addArgs(&.{ "synth", spec });
    const rgb = synth.addOutputFileArg("frames.rgb");
    const truth = synth.addOutputFileArg("truth.json");

    const enc = b.addSystemCommand(&.{
        "ffmpeg",  "-hide_banner", "-loglevel", "error", "-y",
        "-f",      "rawvideo",     "-pix_fmt",  "rgb24", "-s",
        "640x360", "-r",           "10",        "-i",
    });
    enc.setName(b.fmt("roi encode {s}", .{name}));
    enc.addFileArg(rgb);
    enc.addArgs(&.{ "-c:v", "libx264", "-preset", "veryfast", "-crf", b.fmt("{d}", .{c.crf}), "-pix_fmt", "yuv420p" });
    const mp4 = enc.addOutputFileArg("case.mp4");

    const cut = b.addRunArtifact(tool);
    cut.setName(b.fmt("roi cutref {s}", .{name}));
    cut.addArg("cutref");
    cut.addFileArg(mp4);
    cut.addFileArg(truth);
    const ref = cut.addOutputFileArg("ref.png");

    const detect = b.addRunArtifact(exe);
    detect.setName(b.fmt("roi detect {s}", .{name}));
    detect.addArgs(&.{ "detect-roi", "--ref" });
    detect.addFileArg(ref);
    detect.addFileArg(mp4);
    const det = detect.captureStdOut(.{});
    _ = detect.captureStdErr(.{});
    detect.expectExitCode(0);

    const chk = b.addRunArtifact(tool);
    chk.setName(b.fmt("roi check {s}", .{name}));
    chk.addArg("check");
    chk.addFileArg(truth);
    chk.addFileArg(det);
    chk.expectExitCode(0);
    return &chk.step;
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
