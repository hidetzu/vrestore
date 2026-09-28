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
    // 幅・高さが奇数の動画は H.264（4:2:0）に書き出せない。理由を言って、書き始める前に止まること
    const gen_odd = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=10:d=0.5", "-vf", "scale=321:181,format=gbrp", "-c:v", "ffv1" });
    gen_odd.setName("generate odd.mkv");
    const odd_mkv = gen_odd.addOutputFileArg("odd.mkv");
    const cli_odd_out = b.addRunArtifact(exe);
    cli_odd_out.setName("cli_odd_out");
    cli_odd_out.addArgs(&.{ "restore", "--rect", "10,10,20,20", "--out" });
    _ = cli_odd_out.addOutputFileArg("odd-out.mp4");
    cli_odd_out.addFileArg(odd_mkv);
    cli_odd_out.expectStdErrMatch("needs an even width and height");
    cli_odd_out.expectExitCode(1);
    // フルレンジ（yuv420p + color_range=pc）の入力を書き出しても、暗部・明部を潰さない。
    // 明るさだけ 0〜255 の横の傾斜を VP9 の劣化なしで作り、--crf 0 で書き出し、ffmpeg に範囲の記述どおり RGB にさせて比べる。
    // 実測: 直す前は 17 → 0、241 → 255（差の平均 8.22）、直した後は差 0
    const gen_ramp = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=gray:s=320x180:r=10:d=1,format=yuv420p,geq=lum='X*255/319':cb=128:cr=128", "-c:v", "libvpx-vp9", "-lossless", "1", "-pix_fmt", "yuv420p", "-color_range", "pc" });
    gen_ramp.setName("generate full-range ramp");
    const ramp = gen_ramp.addOutputFileArg("ramp.webm");
    const ramp_out = b.addRunArtifact(exe);
    ramp_out.setName("cli_full_range restore");
    ramp_out.addArgs(&.{ "restore", "--rect", "10,10,20,20", "--crf", "0", "--out" });
    const ramp_mp4 = ramp_out.addOutputFileArg("ramp-out.mp4");
    ramp_out.addFileArg(ramp);
    _ = ramp_out.captureStdOut(.{});
    const ramp_chk = b.addSystemCommand(&.{ "sh", "-c",
        \\p=$(ffmpeg -i "$0" -i "$1" -lavfi "[0:v]crop=280:140:40:40,scale=in_range=auto:out_range=full,format=gbrp[a];[1:v]crop=280:140:40:40,scale=in_range=auto:out_range=full,format=gbrp[b];[a][b]psnr" -f null - 2>&1 | grep -o "average:[^ ]*" | cut -d: -f2)
        \\echo "full-range psnr=$p (>= 40)"
        \\[ "$p" = inf ] || awk -v p="$p" 'BEGIN { exit !(p >= 40) }'
    });
    ramp_chk.setName("cli_full_range check");
    ramp_chk.addFileArg(ramp);
    ramp_chk.addFileArg(ramp_mp4);
    ramp_chk.expectExitCode(0);
    // 回転の情報（display matrix）を書き出しに写す。フレームは回さないので、写さないと縦持ちの動画が横倒しになる
    const gen_rot = b.addSystemCommand(&.{ "sh", "-c",
        \\ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=320x180:r=10:d=0.5 -c:v libx264 -pix_fmt yuv420p "$0.tmp.mp4" &&
        \\ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i "$0.tmp.mp4" -c copy "$0" && rm -f "$0.tmp.mp4"
    });
    gen_rot.setName("generate rotated.mp4");
    const rot_mp4 = gen_rot.addOutputFileArg("rotated.mp4");
    const rot_out = b.addRunArtifact(exe);
    rot_out.setName("cli_rotation restore");
    rot_out.addArgs(&.{ "restore", "--rect", "10,10,20,20", "--out" });
    const rot_out_mp4 = rot_out.addOutputFileArg("rotated-out.mp4");
    rot_out.addFileArg(rot_mp4);
    _ = rot_out.captureStdOut(.{});
    const rot_chk = b.addSystemCommand(&.{ "sh", "-c",
        \\r=$(ffprobe -v error -select_streams v -show_entries stream_side_data=rotation -of csv=p=0 "$0")
        \\echo "rotation=$r (want 90)"; [ "$r" = 90 ]
    });
    rot_chk.setName("cli_rotation check");
    rot_chk.addFileArg(rot_out_mp4);
    rot_chk.expectExitCode(0);
    if (test_filters.len == 0) {
        test_step.dependOn(&ramp_chk.step);
        test_step.dependOn(&rot_chk.step);
        test_step.dependOn(&cli_odd_out.step);
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

    // ---- GUI（vrestore-gui）--------------------------------------------------
    // SDL2 が要るので本体とは別の実行ファイルにして、既定の install には入れない（docs/adr/0004）
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkFfmpeg(gui_mod);
    gui_mod.linkSystemLibrary("sdl2", .{ .use_pkg_config = .force });
    // パネルの文字（docs/adr/0009）。pkg-config を使うと SDL2 と SDL2_ttf の両方が SDL2 本体をリンクし、
    // macOS で「duplicate linked dylib」として起動時に止まった（Homebrew の sdl2-compat）。
    // ヘッダは SDL2 と同じ場所にあるので、ライブラリだけを直接リンクする
    gui_mod.linkSystemLibrary("SDL2_ttf", .{ .use_pkg_config = .no });
    const gui = b.addExecutable(.{ .name = "vrestore-gui", .root_module = gui_mod });
    const gui_step = b.step("gui", "Build and install vrestore-gui and vrestore (needs SDL2)");
    gui_step.dependOn(&b.addInstallArtifact(gui, .{}).step);
    // E（書き出し）は隣の vrestore を子プロセスで動かす（docs/adr/0014）
    gui_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run_gui = b.addRunArtifact(gui);
    if (b.args) |args| run_gui.addArgs(args);
    b.step("run-gui", "Run vrestore-gui").dependOn(&run_gui.step);

    // 画面なし（SDL のダミー描画）で、選択 → 検出の経路を Enter と同じ関数で回し、正解と照合する。
    // 位置は正の座標で置き、参照 = ウォーターマーク 146x56（12 文字 x 3 行）+ 余白 6px を --select に渡す。
    // 数字がずれれば roi check が FAIL するので、黙って通ることは無い
    const gui_case = synthCase(b, tool, .{ .spec = "name=gui,bg=pan,x=40,y=30", .crf = 23 });
    const gui_e2e = b.addRunArtifact(gui);
    gui_e2e.setName("gui detect-and-exit");
    gui_e2e.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    gui_e2e.addArgs(&.{ "--at", "0", "--select", "34,24,158,68", "--detect-and-exit" });
    gui_e2e.addFileArg(gui_case.mp4);
    const gui_det = gui_e2e.captureStdOut(.{});
    gui_e2e.expectExitCode(0);
    const gui_chk = b.addRunArtifact(tool);
    gui_chk.setName("roi check gui");
    gui_chk.addArg("check");
    gui_chk.addFileArg(gui_case.truth);
    gui_chk.addFileArg(gui_det);
    gui_chk.expectExitCode(0);
    gui_step.dependOn(&gui_chk.step);

    // 場面の共有（C と同じ 1 行）: --frame で開いた場面、再生の経路（tickTo）で進めた場面、末尾で止まること。
    // steps.mp4 は 10 fps・10 フレーム
    const share_cases = [_]struct { name: []const u8, args: []const []const u8, want: []const u8 }{
        .{ .name = "gui share frame", .args = &.{ "--frame", "7" }, .want = "steps.mp4 t=0.700 frame=7\n" },
        .{ .name = "gui share play", .args = &.{ "--at", "0", "--play-frames", "3" }, .want = "steps.mp4 t=0.300 frame=3\n" },
        .{ .name = "gui share end", .args = &.{ "--frame", "2", "--play-frames", "20" }, .want = "steps.mp4 t=0.900 frame=9\n" },
    };
    for (share_cases) |sc| {
        const run = b.addRunArtifact(gui);
        run.setName(sc.name);
        run.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
        run.addArgs(sc.args);
        run.addArg("--share-and-exit");
        run.addFileArg(steps_mp4);
        run.expectStdOutEqual(sc.want);
        run.expectExitCode(0);
        gui_step.dependOn(&run.step);
    }

    // GUI の R（復元）も、CLI の restore と同じ部品で動くことを画面なしで確かめる。
    // restore-pan7 と同じ合成（中央 240,150、参照 = 146x56 + 余白 6）。表示中のフレームの coverage を見る
    const gui_restore_case = synthCase(b, tool, restore_cases[1].roi);
    const gui_restore = b.addRunArtifact(gui);
    gui_restore.setName("gui restore-and-exit");
    gui_restore.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    gui_restore.addArgs(&.{ "--at", "3", "--select", "234,144,158,68", "--detect-and-exit", "--restore" });
    gui_restore.addFileArg(gui_restore_case.mp4);
    const gui_restore_out = gui_restore.captureStdOut(.{});
    gui_restore.expectExitCode(0);
    const gui_restore_chk = b.addRunArtifact(tool);
    gui_restore_chk.setName("gui restore check");
    gui_restore_chk.addArgs(&.{ "check-restore", "gui-restore" });
    gui_restore_chk.addFileArg(gui_restore_out);
    gui_restore_chk.addFileArg(gui_restore_out);
    // 実測（crf 23、3.0 秒のフレーム）: coverage 1.0000
    gui_restore_chk.addArg("coverage>=0.95");
    gui_restore_chk.expectExitCode(0);
    gui_step.dependOn(&gui_restore_chk.step);

    // GUI の E（全フレームの書き出し）を画面なしで: 同じ合成に音声を付け、子プロセスの vrestore で MP4 にする。
    // フレーム数と、音声のパケットが入力と同じこと
    const gui_audio = addSineAudio(b, "gui export", gui_restore_case.mp4);
    const gui_export = b.addRunArtifact(gui);
    gui_export.setName("gui export-and-exit");
    gui_export.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    gui_export.addArgs(&.{ "--at", "3", "--select", "234,144,158,68", "--detect-and-exit", "--vrestore" });
    gui_export.addArtifactArg(exe);
    gui_export.addArg("--export");
    const gui_export_mp4 = gui_export.addOutputFileArg("gui-export.mp4");
    gui_export.addFileArg(gui_audio);
    const gui_export_out = gui_export.captureStdOut(.{});
    gui_export.expectExitCode(0);
    const gui_export_chk = b.addRunArtifact(tool);
    gui_export_chk.setName("gui export check");
    gui_export_chk.addArgs(&.{ "check-restore", "gui-export" });
    gui_export_chk.addFileArg(gui_export_out);
    gui_export_chk.addFileArg(gui_export_out);
    gui_export_chk.addArg("out.frames>=60,out.frames<=60,out.audio.copied_packets>=1");
    gui_export_chk.expectExitCode(0);
    const gui_export_audio = b.addRunArtifact(tool);
    gui_export_audio.setName("gui export check-audio");
    gui_export_audio.addArg("check-audio");
    gui_export_audio.addFileArg(gui_audio);
    gui_export_audio.addFileArg(gui_export_mp4);
    gui_export_audio.expectExitCode(0);
    gui_export_chk.step.dependOn(&gui_export_audio.step);
    gui_step.dependOn(&gui_export_chk.step);

    // ---- Temporal Recovery の合成 E2E ----------------------------------------
    // 合成 → エンコード → detect-roi → restore → 正解（ウォーターマーク無しの同じ背景）と compare。
    // 判定値は較正（scripts/restore-calibrate.sh、docs/SPEC.md §4）の実測から余裕を取ったもの
    const restore_step = b.step("restore-e2e", "Temporal Recovery on synthetic videos, compared with the clean original");
    for (restore_cases) |c| restore_step.dependOn(restoreCase(b, tool, exe, c));
    restore_step.dependOn(exportCase(b, tool, exe));

    // ---- 復元の指標を FFmpeg と突き合わせる ----------------------------------
    // SSIM / PSNR を自前の実装とだけ比べても何も示さないので、FFmpeg の ssim / psnr フィルタと
    // フレームごとに比べる（src/metrics.zig）。色変換の差を持ち込まないよう、素材は RGB のまま可逆で持つ
    const metrics_step = b.step("metrics", "Cross-check vrestore compare against FFmpeg ssim / psnr");
    metrics_step.dependOn(metricsCrosscheck(b, tool, exe));

    // check: 変更が壊れていないと言うために回すものの全部。
    // 何を回すかはここだけが持つ（.claude/skills/verify/SKILL.md と CI はここを呼ぶ）
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "tools" },
        .check = true,
    });
    const no_media = b.addSystemCommand(&.{"scripts/check-no-media.sh"});
    // git の状態を見るので、毎回実行する（キャッシュさせない）
    no_media.has_side_effects = true;

    const check_step = b.step("check", "fmt --check, test, e2e, restore-e2e, metrics, gui, no-media, build");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(test_step);
    check_step.dependOn(e2e_step);
    check_step.dependOn(metrics_step);
    check_step.dependOn(restore_step);
    check_step.dependOn(gui_step);
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

fn metricsCrosscheck(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile) *std.Build.Step {
    // a: 模様、b: a に時間方向に変わるノイズを足したもの。96x64 / 10 fps / 0.5 秒、ffv1 の gbrp（可逆）
    const gen_a = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=96x64:r=10:d=0.5", "-c:v", "ffv1", "-pix_fmt", "gbrp" });
    gen_a.setName("metrics synth a.mkv");
    const a = gen_a.addOutputFileArg("a.mkv");
    const gen_b = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i" });
    gen_b.setName("metrics synth b.mkv");
    gen_b.addFileArg(a);
    gen_b.addArgs(&.{ "-vf", "noise=alls=20:allf=t", "-c:v", "ffv1", "-pix_fmt", "gbrp" });
    const bv = gen_b.addOutputFileArg("b.mkv");

    // 端数のある位置と大きさ（4 で割り切れない）で、窓の数え方の違いも拾う
    const crop = "crop=41:30:5:7";
    const stats = [_][]const u8{ "ssim", "psnr" };
    var logs: [2]std.Build.LazyPath = undefined;
    for (stats, &logs) |f, *log| {
        const run = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-i" });
        run.setName(b.fmt("metrics ffmpeg {s}", .{f}));
        run.addFileArg(a);
        run.addArg("-i");
        run.addFileArg(bv);
        run.addArgs(&.{ "-lavfi", b.fmt("[0]{s}[x];[1]{s}[y];[x][y]{s}=stats_file=-", .{ crop, crop, f }), "-f", "null", "-" });
        log.* = run.captureStdOut(.{});
    }

    const ours = b.addRunArtifact(exe);
    ours.setName("metrics vrestore compare");
    ours.addArgs(&.{ "compare", "--per-frame", "--rect", "5,7,41,30" });
    ours.addFileArg(a);
    ours.addFileArg(bv);
    const ours_out = ours.captureStdOut(.{});

    const chk = b.addRunArtifact(tool);
    chk.setName("metrics crosscheck");
    chk.addArg("crossmetrics");
    chk.addFileArg(ours_out);
    chk.addFileArg(logs[0]);
    chk.addFileArg(logs[1]);
    chk.expectExitCode(0);
    return &chk.step;
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

const RestoreCase = struct {
    roi: RoiCase,
    /// restore --motion。null なら既定（restore_cmd.default_motion）
    motion: ?[]const u8 = null,
    /// restore --fill。null なら既定（restore_cmd.default_fill）
    fill: ?[]const u8 = null,
    /// restore --mask。"auto" なら、本物のウォーターマークの画素を取りこぼしていないかも判定する（再現率 >= 0.99）
    mask: ?[]const u8 = null,
    /// tools/roi_fixture check-restore の条件
    expect: []const u8,
};

const restore_cases = [_]RestoreCase{
    // 実測（crf 23）: coverage 1.000、SSIM 0.947（再エンコードだけの上限 0.948）、戻した画素の PSNR 38.2
    .{ .roi = .{ .spec = "name=restore-pan15,bg=pan,pan_x=15,pan_y=0,x=240,y=150,frames=60", .crf = 23 }, .expect = "coverage>=0.99,ssim>=0.9,masked_psnr>=35,provenance.temporal_real.fraction>=0.99" },
    // 実測: coverage 0.988、SSIM 0.926、戻した画素の PSNR 37.5
    .{ .roi = .{ .spec = "name=restore-pan7,bg=pan,pan_x=7,pan_y=3,x=240,y=150,frames=60", .crf = 23 }, .expect = "coverage>=0.95,ssim>=0.88,masked_psnr>=34" },
    // 同じ素材を平行移動のモデルで（--motion translation の経路を回し続ける）
    .{ .roi = .{ .spec = "name=restore-pan7-translation,bg=pan,pan_x=7,pan_y=3,x=240,y=150,frames=60", .crf = 23 }, .motion = "translation", .expect = "coverage>=0.95,ssim>=0.88,masked_psnr>=34" },
    // 遅いパン × 強い圧縮。全帯域の位相相関だと x264 のブロックの格子が (0,0) のピークを作り、動いていないと
    // 推定した（CLAUDE.md §7）。実測（低い周波数だけ）: coverage 0.680、戻した画素の PSNR 32.2
    .{ .roi = .{ .spec = "name=restore-pan3-crf35,bg=pan,pan_x=3,pan_y=1,x=240,y=150,frames=60", .crf = 35 }, .expect = "coverage>=0.6,masked_psnr>=30" },
    // ズームする背景（画面全体の平行移動ではない動き）。平行移動で近似して借りると外れた画素を貼る。
    // ROI の周りの帯が合わないフレームからは借りないので、戻した画素のほとんどは正しいこと
    .{ .roi = .{ .spec = "name=restore-zoom,bg=zoom,x=240,y=150,frames=60", .crf = 23 }, .expect = "masked_bad_fraction<=0.02" },
    // 回転 + パン（画面全体の平行移動ではない動き）。affine で動きを追えば戻せる。
    // 較正（crf 23 を含む 12 ケースの平均）: 平行移動 SSIM 0.464・coverage 0.573、affine 0.813・0.908
    .{ .roi = .{ .spec = "name=restore-rotpan,bg=warp,rot=0.2,pan_x=5,pan_y=2,x=240,y=150,frames=60", .crf = 23 }, .expect = "coverage>=0.8,ssim>=0.75,masked_bad_fraction<=0.01" },
    // 毎フレーム別の模様: 動きで説明できないので、1 画素も貼らない
    // 由来はすべて unrecovered（戻さなかった画素を戻したと数えない）
    .{ .roi = .{ .spec = "name=restore-cut,bg=cut,x=240,y=150,frames=60", .crf = 23 }, .expect = "coverage<=0,provenance.unrecovered.fraction>=1" },
    // 動かない滑らかな背景を、周囲から推測して埋める（--fill harmonic）。背景が動かないので、埋めた画素は
    // 前のフレームと混ぜて落ち着かせる（stable_fill.blended = 59 / 59）。
    // 埋めた画素は spatial_inpainted で、coverage には数えない。実測（crf 23）: SSIM 0.997、PSNR 42.9
    .{ .roi = .{ .spec = "name=restore-flat-fill,bg=flat,x=240,y=150,frames=60", .crf = 23 }, .fill = "harmonic", .expect = "coverage<=0,provenance.spatial_inpainted.fraction>=0.99,ssim>=0.95,stable_fill.blended>=59" },
    // パンで Temporal が戻せなかった残りだけを埋める。戻した実画素はそのまま。背景が動くので、埋めた画素を
    // 前のフレームと混ぜない（混ぜると別の場所の推測が重なる）。実測: SSIM 0.928 → 0.942
    .{ .roi = .{ .spec = "name=restore-pan7-fill,bg=pan,pan_x=7,pan_y=3,x=240,y=150,frames=60", .crf = 23 }, .fill = "harmonic", .expect = "coverage>=0.95,ssim>=0.935,masked_psnr>=34,provenance.temporal_real.fraction>=0.95,stable_fill.blended<=0" },
    // 毎フレーム別の模様を、ウォーターマークの画素だけ埋める（--mask auto）。本物の背景が見えている画素は残す。
    // 実測（crf 23）: ROI 全体を埋めると SSIM 0.649、マスクで 0.758。再現率 1.0000
    .{ .roi = .{ .spec = "name=restore-cut-mask,bg=cut,x=240,y=150,frames=60", .crf = 23 }, .fill = "harmonic", .mask = "auto", .expect = "coverage<=0,ssim>=0.67,mask_accepted>=1" },
    // 動かない背景: 隠れた画素はどのフレームにも写っていないので、1 画素も戻らない
    .{ .roi = .{ .spec = "name=restore-flat,bg=flat,x=240,y=150,frames=60", .crf = 23 }, .expect = "coverage<=0" },
};

fn restoreCase(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile, c: RestoreCase) *std.Build.Step {
    const name = c.roi.spec[5..std.mem.indexOfScalar(u8, c.roi.spec, ',').?];
    const v = synthCase(b, tool, c.roi);
    const spec = b.fmt("{s},crf={d}", .{ c.roi.spec, c.roi.crf });

    // 正解: 同じケースをウォーターマーク無しで合成し、可逆で持つ
    const clean = b.addRunArtifact(tool);
    clean.setName(b.fmt("{s} synth-clean", .{name}));
    clean.addArgs(&.{ "synth-clean", spec });
    const clean_rgb = clean.addOutputFileArg("clean.rgb");
    _ = clean.addOutputFileArg("truth-clean.json");
    const clean_mkv = rawToFfv1(b, b.fmt("{s} encode clean", .{name}), clean_rgb, "clean.mkv");

    const cut = b.addRunArtifact(tool);
    cut.setName(b.fmt("{s} cutref", .{name}));
    cut.addArg("cutref");
    cut.addFileArg(v.mp4);
    cut.addFileArg(v.truth);
    const ref = cut.addOutputFileArg("ref.png");
    const detect = b.addRunArtifact(exe);
    detect.setName(b.fmt("{s} detect", .{name}));
    detect.addArgs(&.{ "detect-roi", "--ref" });
    detect.addFileArg(ref);
    detect.addFileArg(v.mp4);
    const roi_json = detect.captureStdOut(.{});
    _ = detect.captureStdErr(.{});

    const restore = b.addRunArtifact(exe);
    restore.setName(b.fmt("{s} restore", .{name}));
    restore.addArg("restore");
    if (c.motion) |m| restore.addArgs(&.{ "--motion", m });
    if (c.fill) |f| restore.addArgs(&.{ "--fill", f });
    if (c.mask) |m| restore.addArgs(&.{ "--mask", m });
    restore.addArg("--roi");
    restore.addFileArg(roi_json);
    restore.addArg("--raw");
    const out_rgb = restore.addOutputFileArg("restored.rgb");
    restore.addArg("--provenance");
    const prov = restore.addOutputFileArg("provenance.bin");
    restore.addFileArg(v.mp4);
    const restore_json = restore.captureStdOut(.{});
    const restored_mkv = rawToFfv1(b, b.fmt("{s} encode restored", .{name}), out_rgb, "restored.mkv");

    const cmp = b.addRunArtifact(exe);
    cmp.setName(b.fmt("{s} compare", .{name}));
    cmp.addArgs(&.{ "compare", "--roi" });
    cmp.addFileArg(roi_json);
    cmp.addArg("--provenance");
    cmp.addFileArg(prov);
    cmp.addFileArg(clean_mkv);
    cmp.addFileArg(restored_mkv);
    const cmp_json = cmp.captureStdOut(.{});

    const chk = b.addRunArtifact(tool);
    chk.setName(b.fmt("{s} check", .{name}));
    chk.addArgs(&.{ "check-restore", name });
    chk.addFileArg(restore_json);
    chk.addFileArg(cmp_json);
    chk.addArg(c.expect);
    chk.expectExitCode(0);

    if (c.mask != null) {
        // 焼いたウォーターマークの本当の画素と、隠れている扱いにした画素（由来が original 以外）を比べる
        const truth_mask = b.addRunArtifact(tool);
        truth_mask.setName(b.fmt("{s} synth-mask", .{name}));
        truth_mask.addArgs(&.{ "synth-mask", spec });
        const mask_bin = truth_mask.addOutputFileArg("mask.bin");
        const mchk = b.addRunArtifact(tool);
        mchk.setName(b.fmt("{s} check-mask", .{name}));
        mchk.addArg("check-mask");
        mchk.addFileArg(mask_bin);
        mchk.addFileArg(prov);
        mchk.addArgs(&.{ "640", "360", "0.99" });
        mchk.expectExitCode(0);
        chk.step.dependOn(&mchk.step);
    }
    return &chk.step;
}

/// restore --out の合成 E2E: 背景がパンする合成動画に正弦波の音声（AAC）を付け、MP4 に書き出す。
/// - 音声のパケットが、数も中身も入力と同じ（再符号化していない）
/// - フレーム数が入力と同じ（60）
/// - --raw で同時に書いた RGB と比べて、符号化で落ちる分しか違わない（実測は mp4 と raw の比較で PSNR・SSIM）
fn exportCase(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile) *std.Build.Step {
    const name = "restore-export";
    const roi_case: RoiCase = .{ .spec = "name=restore-export,bg=pan,pan_x=7,pan_y=3,x=240,y=150,frames=60", .crf = 23 };
    const v = synthCase(b, tool, roi_case);
    const with_audio = addSineAudio(b, name, v.mp4);

    const cut = b.addRunArtifact(tool);
    cut.setName(name ++ " cutref");
    cut.addArg("cutref");
    cut.addFileArg(v.mp4);
    cut.addFileArg(v.truth);
    const ref = cut.addOutputFileArg("ref.png");
    const detect = b.addRunArtifact(exe);
    detect.setName(name ++ " detect");
    detect.addArgs(&.{ "detect-roi", "--ref" });
    detect.addFileArg(ref);
    detect.addFileArg(with_audio);
    const roi_json = detect.captureStdOut(.{});
    _ = detect.captureStdErr(.{});

    const restore = b.addRunArtifact(exe);
    restore.setName(name ++ " restore");
    restore.addArgs(&.{ "restore", "--fill", "harmonic", "--roi" });
    restore.addFileArg(roi_json);
    restore.addArg("--raw");
    const out_rgb = restore.addOutputFileArg("restored.rgb");
    restore.addArg("--out");
    const out_mp4 = restore.addOutputFileArg("restored.mp4");
    restore.addFileArg(with_audio);
    const restore_json = restore.captureStdOut(.{});
    const raw_mkv = rawToFfv1(b, name ++ " encode raw", out_rgb, "raw.mkv");

    const cmp = b.addRunArtifact(exe);
    cmp.setName(name ++ " compare mp4 with raw");
    cmp.addArg("compare");
    cmp.addFileArg(raw_mkv);
    cmp.addFileArg(out_mp4);
    const cmp_json = cmp.captureStdOut(.{});

    const chk = b.addRunArtifact(tool);
    chk.setName(name ++ " check");
    chk.addArgs(&.{ "check-restore", name });
    chk.addFileArg(restore_json);
    chk.addFileArg(cmp_json);
    chk.addArg("out.frames>=60,out.frames<=60,out.audio.copied_packets>=1,psnr>=38,ssim>=0.97");
    chk.expectExitCode(0);

    const achk = b.addRunArtifact(tool);
    achk.setName(name ++ " check-audio");
    achk.addArg("check-audio");
    achk.addFileArg(with_audio);
    achk.addFileArg(out_mp4);
    achk.expectExitCode(0);
    chk.step.dependOn(&achk.step);
    return &chk.step;
}

/// 合成の動画（6 秒）に、440 Hz の正弦波の AAC を付ける（書き出しが音声を写すかを見るため）
fn addSineAudio(b: *std.Build, name: []const u8, mp4: std.Build.LazyPath) std.Build.LazyPath {
    const mux = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i" });
    mux.setName(b.fmt("{s} add audio", .{name}));
    mux.addFileArg(mp4);
    mux.addArgs(&.{ "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6", "-c:v", "copy", "-c:a", "aac", "-shortest" });
    return mux.addOutputFileArg("with-audio.mp4");
}

/// RGB24 の生フレーム（640x360、10 fps。synthCase と同じ）を ffv1 の可逆で包む
fn rawToFfv1(b: *std.Build, step_name: []const u8, rgb: std.Build.LazyPath, out_name: []const u8) std.Build.LazyPath {
    const enc = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "640x360", "-r", "10", "-i" });
    enc.setName(step_name);
    enc.addFileArg(rgb);
    enc.addArgs(&.{ "-c:v", "ffv1", "-pix_fmt", "gbrp" });
    return enc.addOutputFileArg(out_name);
}

const SynthVideo = struct { truth: std.Build.LazyPath, mp4: std.Build.LazyPath };

/// tools/roi_fixture で合成し、ffmpeg で yuv420p にエンコードする
fn synthCase(b: *std.Build, tool: *std.Build.Step.Compile, c: RoiCase) SynthVideo {
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
    return .{ .truth = truth, .mp4 = enc.addOutputFileArg("case.mp4") };
}

fn roiCase(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile, c: RoiCase) *std.Build.Step {
    const name = c.spec[5..std.mem.indexOfScalar(u8, c.spec, ',').?];
    const v = synthCase(b, tool, c);
    const truth = v.truth;
    const mp4 = v.mp4;

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
