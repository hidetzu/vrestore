//! vrestore-gui: 動画のフレームを見ながらウォーターマークの範囲を矩形で選び、ROI 検出にかける最小の UI。
//!
//! ここは SDL2 でイベントを読んで描くだけの薄い層。座標計算と選択は gui_state.zig、
//! 検出は detect_roi.detectInVideo（CLI の detect-roi と同じ入口）を呼ぶ。検出のロジックはここに書かない
//! （docs/adr/0004）。
//!
//! 操作:
//!   Space                    再生 / 一時停止（操作パネルの ▶ でも同じ）
//!   操作パネル               映像の上に重なる。シークバーで移動、地の部分をドラッグでパネルを動かす
//!   H                        操作パネルを隠す / 出す
//!   C                        今の場面（動画名・時刻・フレーム番号）をクリップボードにコピーし、標準出力にも出す
//!   ドラッグ（フレーム上）   ウォーターマークの範囲を選ぶ（パネルの上では選択にならない。選択中はパネルを隠す）
//!   Enter / D                選んだ範囲を参照画像にして検出する
//!   R                        検出した ROI を、前後のフレームの実画素で戻す（Temporal Recovery）
//!   B                        処理前 / 処理後を切り替える（処理後で戻せなかった画素はマゼンタ）
//!   P                        処理後の画面に、各画素の由来（provenance）を色で重ねる / 外す
//!   M                        動きのモデルを切り替える（translation / affine）。次の R から使う
//!   F                        戻せなかった画素を周囲から推測して埋めるか切り替える（none / harmonic）。次の R から使う
//!   ← / →                    1 フレーム戻る / 進む（Shift で 1 秒、↑ / ↓ で 10 秒）
//!   Home / End               先頭 / 末尾
//!   Esc                      選択と検出結果を消す
//!   Q / 窓を閉じる           終了

const std = @import("std");
const Io = std.Io;
const video = @import("video.zig");
const roi = @import("roi.zig");
const detect_roi = @import("detect_roi.zig");
const state = @import("gui_state.zig");
const compare = @import("compare.zig");
const temporal = @import("temporal.zig");
const restore_cmd = @import("restore_cmd.zig");
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;
const spatial = @import("spatial.zig");
const ps = @import("player_state.zig");
const glyphs = @import("glyphs.zig");
const fonts = @import("fonts.zig");

/// パネルの文字。SDL_ttf でシステムのフォントを描く（ASCII のグリフを一度だけテクスチャにして使い回す）。
/// フォントが見つからなければ、内蔵のビットマップフォント（数字と記号だけ）で描く（docs/adr/0009）
const Text = struct {
    ren: *sdl.SDL_Renderer,
    font: ?*sdl.TTF_Font,
    glyph: [95]?Glyph = .{null} ** 95,
    /// 数字の送り幅（すべての数字をこの幅で並べ、再生中に時刻の文字が揺れないようにする）
    digit_adv: f32 = 0,
    line_h: f32,

    const Glyph = struct { tex: *sdl.SDL_Texture, w: f32, h: f32, adv: f32 };
    /// ビットマップフォントのときの倍率
    const bitmap_scale = 2;

    fn init(ren: *sdl.SDL_Renderer, path: ?[]const u8, pt: c_int) Text {
        var t: Text = .{ .ren = ren, .font = null, .line_h = glyphs.height * bitmap_scale };
        const p = path orelse return t;
        if (sdl.TTF_WasInit() == 0 and sdl.TTF_Init() != 0) return t;
        var zbuf: [1024]u8 = undefined;
        if (p.len >= zbuf.len) return t;
        @memcpy(zbuf[0..p.len], p);
        zbuf[p.len] = 0;
        const font = sdl.TTF_OpenFont(@ptrCast(&zbuf), pt) orelse return t;
        t.font = font;
        t.line_h = @floatFromInt(sdl.TTF_FontHeight(font));
        const white: sdl.SDL_Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        for (32..127) |c| {
            var minx: c_int = 0;
            var maxx: c_int = 0;
            var miny: c_int = 0;
            var maxy: c_int = 0;
            var adv: c_int = 0;
            if (sdl.TTF_GlyphMetrics(font, @intCast(c), &minx, &maxx, &miny, &maxy, &adv) != 0) continue;
            const surf = sdl.TTF_RenderGlyph_Blended(font, @intCast(c), white) orelse continue;
            defer sdl.SDL_FreeSurface(surf);
            const tex = sdl.SDL_CreateTextureFromSurface(ren, surf) orelse continue;
            t.glyph[c - 32] = .{ .tex = tex, .w = @floatFromInt(surf.*.w), .h = @floatFromInt(surf.*.h), .adv = @floatFromInt(adv) };
            if (c >= '0' and c <= '9') t.digit_adv = @max(t.digit_adv, @as(f32, @floatFromInt(adv)));
        }
        return t;
    }

    fn deinit(t: *Text) void {
        for (t.glyph) |g| if (g) |gg| sdl.SDL_DestroyTexture(gg.tex);
        if (t.font) |f| sdl.TTF_CloseFont(f);
    }

    fn advance(t: *const Text, c: u8) f32 {
        if (t.font == null) return (glyphs.width + glyphs.spacing) * bitmap_scale;
        if (c >= '0' and c <= '9') return t.digit_adv;
        if (c < 32 or c > 126) return 0;
        return if (t.glyph[c - 32]) |g| g.adv else 0;
    }

    fn width(t: *const Text, s: []const u8) f32 {
        var w: f32 = 0;
        for (s) |c| w += t.advance(c);
        return w;
    }

    /// (x, 行の上端 y) から、高さ h の行の縦中央に描く
    fn draw(t: *const Text, s: []const u8, x: f32, y: f32, h: f32, col: [3]u8, alpha: u8) void {
        const top = y + (h - t.line_h) / 2;
        if (t.font == null) {
            const Ctx = struct { ren: *sdl.SDL_Renderer, x: f32, y: f32 };
            _ = sdl.SDL_SetRenderDrawColor(t.ren, col[0], col[1], col[2], alpha);
            glyphs.render(s, bitmap_scale, Ctx{ .ren = t.ren, .x = x, .y = top }, struct {
                fn f(c: Ctx, px: u32, py: u32) void {
                    _ = sdl.SDL_RenderFillRectF(c.ren, &.{ .x = c.x + @as(f32, @floatFromInt(px)), .y = c.y + @as(f32, @floatFromInt(py)), .w = bitmap_scale, .h = bitmap_scale });
                }
            }.f);
            return;
        }
        var cx = x;
        for (s) |c| {
            const adv = t.advance(c);
            if (c >= 32 and c <= 126) if (t.glyph[c - 32]) |g| {
                _ = sdl.SDL_SetTextureColorMod(g.tex, col[0], col[1], col[2]);
                _ = sdl.SDL_SetTextureAlphaMod(g.tex, alpha);
                // 数字は送り幅の中で中央に置く
                const off = if (c >= '0' and c <= '9') (adv - g.adv) / 2 else 0;
                _ = sdl.SDL_RenderCopyF(t.ren, g.tex, null, &.{ .x = cx + off, .y = top, .w = g.w, .h = g.h });
            };
            cx += adv;
        }
    }
};

const sdl = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_ttf.h");
});

const usage =
    \\usage: vrestore-gui [--at <sec> | --frame <n>] [--select x,y,w,h --detect-and-exit] <video>
    \\
    \\Drag over the watermark, then press Enter to find where it is fixed in the video.
    \\  --at <sec>              start at this time
    \\  --frame <n>             start at this frame (0 = first; as printed by C)
    \\  --play-frames <n>       with --share-and-exit, play n frames first (the same path as playback)
    \\  --share-and-exit        print the current scene as "name t=<sec> frame=<n>" and exit (as C)
    \\  --font <path>           font for the control panel (also VRESTORE_FONT); default: a system font
    \\  --select x,y,w,h        start with this selection (frame pixels)
    \\  --detect-and-exit       run the detection on --select once, print the JSON and exit
    \\                          (the same path as pressing Enter; used by the tests)
    \\  --restore               with --detect-and-exit, also restore the current frame (as pressing R)
    \\                          and print its coverage as a second JSON line
    \\  --show-provenance       with --restore, show the provenance colors (as pressing P)
    \\  --motion <m>            translation or affine (as pressing M)
    \\  --fill <f>              none, directional or harmonic (F toggles none / harmonic)
    \\  --screenshot <png>      with --detect-and-exit, also save what the window shows
    \\
;

/// 下端の帯（検出の得票率の棒）の高さ。時刻の移動は操作パネルのシークバーで行う
const bar_h = 14;

const App = struct {
    gpa: std.mem.Allocator,
    path: [:0]const u8,
    dec: video.Decoder,
    rgb: []u8,
    time_sec: f64 = 0,
    duration: f64,
    frame_dur: f64,
    selection: state.Selection = .{},
    detection: ?roi.Detection = null,
    /// 表示中のフレームを戻したもの（R）。フレームを動かすと捨てる
    restored: ?[]u8 = null,
    /// 各画素の由来（フレーム全体）
    restored_prov: ?[]Provenance = null,
    recovered: provenance.Tally = .{},
    show_after: bool = false,
    /// 処理後の画面に由来の色を重ねる（P）
    show_provenance: bool = false,
    /// 動きのモデル（M で切り替え）
    motion_model: restore_cmd.MotionModel = restore_cmd.default_motion,
    /// 戻せなかった画素を埋める方式（F で切り替え）
    fill: spatial.Method = restore_cmd.default_fill,
    /// 表示用の画素（処理後で、戻せなかった画素をマゼンタにしたもの）
    display: []u8,
    /// 映像の上に重ねる操作パネルと、再生の時計
    panel: ps.Panel = .{ .x = 0, .y = 0 },
    clock: ps.Clock = .{},
    fps: f64,
    /// 共有用の 1 行に出す動画の名前（パスの最後）
    video_name: []const u8,
    /// パネルの文字（SDL の初期化の後に入れる）
    text: ?*const Text = null,
    /// 検出できなかったときの理由（窓のタイトルに出す）
    problem: [256]u8 = undefined,
    problem_len: usize = 0,

    fn clearRestored(app: *App) void {
        if (app.restored) |r| app.gpa.free(r);
        if (app.restored_prov) |m| app.gpa.free(m);
        app.restored = null;
        app.restored_prov = null;
        app.show_after = false;
    }

    /// 検出した ROI を、表示中のフレームの前後 `window` 枚の実画素で戻す。
    /// 動きの推定と復元は restore_cmd.recoverInWindow（CLI の restore と同じ部品、同じ閾値）
    fn restore(app: *App) !void {
        app.clearRestored();
        app.problem_len = 0;
        const det = app.detection orelse return app.setProblem("detect the ROI first (Enter)", .{});
        const window = 15;
        const roi_rect: temporal.Rect = .{ .x = @intCast(det.x), .y = @intCast(det.y), .w = @intCast(det.width), .h = @intCast(det.height) };

        var d = try video.Decoder.open(app.path);
        defer d.close();
        try d.seek(@max(0, app.time_sec - @as(f64, @floatFromInt(window)) * app.frame_dur));
        var bufs: std.ArrayList([]u8) = .empty;
        defer {
            for (bufs.items) |b| app.gpa.free(b);
            bufs.deinit(app.gpa);
        }
        var target: ?usize = null;
        var best_dt: f64 = std.math.inf(f64);
        while (bufs.items.len < 2 * window + 1) {
            const buf = try app.gpa.alloc(u8, d.frameBytes());
            const f = (try d.next(buf)) orelse {
                app.gpa.free(buf);
                break;
            };
            try bufs.append(app.gpa, buf);
            const dt = @abs(f.time_sec - app.time_sec);
            if (dt < best_dt) {
                best_dt = dt;
                target = bufs.items.len - 1;
            }
            // 表示中のフレームより後ろを window 枚読んだら十分
            if (target) |t| if (bufs.items.len > t + window) break;
        }
        const t = target orelse return app.setProblem("no frame to restore", .{});
        const images = try app.gpa.alloc(temporal.Image, bufs.items.len);
        defer app.gpa.free(images);
        for (bufs.items, images) |b, *img| img.* = .{ .width = d.info.width, .height = d.info.height, .rgb = b };

        const out = try app.gpa.alloc(u8, d.frameBytes());
        errdefer app.gpa.free(out);
        const prov = try app.gpa.alloc(Provenance, @as(usize, d.info.width) * d.info.height);
        errdefer app.gpa.free(prov);
        app.recovered = try restore_cmd.recoverInWindow(app.gpa, app.motion_model, app.fill, images, t, roi_rect, restore_cmd.default_min_peak, restore_cmd.default_max_ring_diff, out, prov);
        app.restored = out;
        app.restored_prov = prov;
        app.show_after = true;
    }

    /// 画面に出す画素。処理後なら戻した画素、戻せなかった画素はマゼンタ（推測で埋めていないことを見せる）。
    /// P を押していれば、由来ごとの色（Provenance.color）を半分重ねる。未復元は常にマゼンタで塗る
    fn pixels(app: *App) []const u8 {
        if (!app.show_after) return app.rgb;
        const r = app.restored orelse return app.rgb;
        const prov = app.restored_prov.?;
        @memcpy(app.display, r);
        for (prov, 0..) |p, i| {
            const col = p.color() orelse continue;
            const px = app.display[i * 3 ..][0..3];
            if (p == .unrecovered) {
                px.* = col;
            } else if (app.show_provenance) {
                for (px, col) |*v, c| v.* = @intCast((@as(u16, v.*) + c) / 2);
            }
        }
        return app.display;
    }

    fn togglePlay(app: *App) void {
        if (app.clock.playing) {
            app.clock.pause();
        } else {
            app.clearRestored();
            // 末尾で押したら先頭から
            const at = if (app.time_sec >= app.duration - app.frame_dur) 0 else app.time_sec;
            app.clock.play(sdl.SDL_GetTicks64(), at);
        }
    }

    fn pause(app: *App) void {
        app.clock.pause();
    }

    /// 再生中の 1 刻み: 時計が指す時刻まで、フレームを読み進めるか seek する（player_state.advance）
    fn tickTo(app: *App, target: f64) !bool {
        switch (ps.advance(app.time_sec, target, app.frame_dur)) {
            .wait => return false,
            .frames => |n| {
                for (0..n) |_| {
                    const f = (try app.dec.next(app.rgb)) orelse {
                        // 末尾に着いた
                        app.clock.pause();
                        return true;
                    };
                    app.time_sec = f.time_sec;
                }
                app.clearRestored();
                return true;
            },
            .seek => |t| {
                const playing = app.clock.playing;
                try app.showAt(t);
                // showAt は時計を合わせ直すので、再生中ならそのまま続ける
                app.clock.playing = playing;
                return true;
            },
        }
    }

    fn shareLine(app: *const App, buf: []u8) []const u8 {
        return ps.shareLine(buf, app.video_name, app.time_sec, app.fps);
    }

    fn showAt(app: *App, sec: f64) !void {
        // 再生中にシークしたら、そこから再生を続ける
        if (app.clock.playing) app.clock.play(sdl.SDL_GetTicks64(), std.math.clamp(sec, 0, app.duration));
        app.clearRestored();
        const t = std.math.clamp(sec, 0, @max(0, app.duration - app.frame_dur));
        try app.dec.seek(t);
        if (try app.dec.next(app.rgb)) |f| app.time_sec = f.time_sec;
    }

    fn step(app: *App) !void {
        app.clearRestored();
        // 1 フレーム進むのは seek せずに次を読むだけ
        if (try app.dec.next(app.rgb)) |f| app.time_sec = f.time_sec;
    }

    /// 選択範囲を参照画像にして検出する。Enter と --detect-and-exit はどちらもここを通る
    fn detect(app: *App) !void {
        app.clearRestored();
        app.detection = null;
        app.problem_len = 0;
        const sel = app.selection.rect orelse return app.setProblem("select the watermark by dragging first", .{});
        var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const ref_rgb = try state.crop(arena, app.rgb, app.dec.info.width, sel);
        const ref: roi.Image = .{ .width = sel.w, .height = sel.h, .rgb = ref_rgb };
        // 表示中のデコーダの位置を崩さないよう、検出用に開き直す
        var d = try video.Decoder.open(app.path);
        defer d.close();
        const result = detect_roi.detectInVideo(arena, app.gpa, &d, ref, 15, detect_roi.default_thresholds) catch |e| {
            var w: Io.Writer = .fixed(&app.problem);
            detect_roi.describeProblem(&w, e, ref, d.info) catch {};
            app.problem_len = w.end;
            return;
        };
        app.detection = result.detection;
    }

    fn setProblem(app: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&app.problem, fmt, args) catch app.problem[0..0];
        app.problem_len = s.len;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var out_buf: [1024]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    defer out.interface.flush() catch {};
    defer err.interface.flush() catch {};
    video.c.av_log_set_level(video.c.AV_LOG_QUIET);

    var path: ?[]const u8 = null;
    var at: f64 = 0;
    var select: ?state.Rect = null;
    var detect_and_exit = false;
    var restore_too = false;
    var frame_arg: ?u64 = null;
    var play_frames: u64 = 0;
    var share_and_exit = false;
    var font_arg: ?[]const u8 = null;
    var show_prov = false;
    var motion_model = restore_cmd.default_motion;
    var fill_method = restore_cmd.default_fill;
    var screenshot: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--detect-and-exit")) {
            detect_and_exit = true;
        } else if (std.mem.eql(u8, a, "--frame") and i + 1 < args.len) {
            i += 1;
            frame_arg = std.fmt.parseInt(u64, args[i], 10) catch return badArg(&err.interface, "--frame needs a frame number", args[i]);
        } else if (std.mem.eql(u8, a, "--play-frames") and i + 1 < args.len) {
            i += 1;
            play_frames = std.fmt.parseInt(u64, args[i], 10) catch return badArg(&err.interface, "--play-frames needs a number", args[i]);
        } else if (std.mem.eql(u8, a, "--font") and i + 1 < args.len) {
            i += 1;
            font_arg = args[i];
        } else if (std.mem.eql(u8, a, "--share-and-exit")) {
            share_and_exit = true;
        } else if (std.mem.eql(u8, a, "--restore")) {
            restore_too = true;
        } else if (std.mem.eql(u8, a, "--show-provenance")) {
            show_prov = true;
        } else if (std.mem.eql(u8, a, "--fill") and i + 1 < args.len) {
            i += 1;
            fill_method = std.meta.stringToEnum(spatial.Method, args[i]) orelse return badArg(&err.interface, "--fill needs none, directional or harmonic", args[i]);
        } else if (std.mem.eql(u8, a, "--motion") and i + 1 < args.len) {
            i += 1;
            motion_model = std.meta.stringToEnum(restore_cmd.MotionModel, args[i]) orelse return badArg(&err.interface, "--motion needs translation or affine", args[i]);
        } else if (std.mem.eql(u8, a, "--at") and i + 1 < args.len) {
            i += 1;
            at = std.fmt.parseFloat(f64, args[i]) catch return badArg(&err.interface, "--at needs seconds", args[i]);
        } else if (std.mem.eql(u8, a, "--screenshot") and i + 1 < args.len) {
            i += 1;
            screenshot = args[i];
        } else if (std.mem.eql(u8, a, "--select") and i + 1 < args.len) {
            i += 1;
            select = parseRect(args[i]) orelse return badArg(&err.interface, "--select needs x,y,w,h", args[i]);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try out.interface.writeAll(usage);
            return 0;
        } else if (!std.mem.startsWith(u8, a, "--") and path == null) {
            path = a;
        } else {
            return badArg(&err.interface, "unknown argument", a);
        }
    }
    const p = path orelse {
        try err.interface.writeAll(usage);
        return 2;
    };
    if (detect_and_exit and select == null) return badArg(&err.interface, "--detect-and-exit needs --select", "--detect-and-exit");

    const path_z = try arena.dupeZ(u8, p);
    var dec = video.Decoder.open(path_z) catch |e| {
        try err.interface.print("vrestore-gui: could not open '{s}': {s}\n", .{ p, video.describe(e) });
        return 1;
    };
    defer dec.close();
    const fps = dec.info.frame_rate orelse 30;
    var app: App = .{
        .gpa = gpa,
        .path = path_z,
        .dec = dec,
        .rgb = try arena.alloc(u8, dec.frameBytes()),
        .display = try arena.alloc(u8, dec.frameBytes()),
        .duration = dec.info.duration_sec orelse 0,
        .motion_model = motion_model,
        .fill = fill_method,
        .fps = fps,
        .video_name = std.fs.path.basename(p),
        .frame_dur = 1 / fps,
    };
    try app.showAt(if (frame_arg) |n| ps.frameToSec(n, fps) else at);
    if (select) |r| {
        if (r.w == 0 or r.h == 0 or @as(u64, r.x) + r.w > dec.info.width or @as(u64, r.y) + r.h > dec.info.height)
            return badArg(&err.interface, "--select goes outside the frame", "--select");
        app.selection.rect = r;
    }

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) {
        try err.interface.print("vrestore-gui: could not start SDL: {s}\n", .{sdl.SDL_GetError()});
        return 1;
    }
    defer sdl.SDL_Quit();
    // 初期の窓は 1280 幅に収まる大きさ
    const scale0 = @min(1.0, 1280.0 / @as(f64, @floatFromInt(dec.info.width)));
    const win = sdl.SDL_CreateWindow(
        "vrestore-gui",
        100,
        100,
        @intFromFloat(@as(f64, @floatFromInt(dec.info.width)) * scale0),
        @as(c_int, @intFromFloat(@as(f64, @floatFromInt(dec.info.height)) * scale0)) + bar_h,
        sdl.SDL_WINDOW_RESIZABLE,
    ) orelse {
        try err.interface.print("vrestore-gui: could not open a window: {s}\n", .{sdl.SDL_GetError()});
        return 1;
    };
    defer sdl.SDL_DestroyWindow(win);
    const ren = sdl.SDL_CreateRenderer(win, -1, sdl.SDL_RENDERER_ACCELERATED) orelse
        sdl.SDL_CreateRenderer(win, -1, sdl.SDL_RENDERER_SOFTWARE) orelse {
        try err.interface.print("vrestore-gui: could not create a renderer: {s}\n", .{sdl.SDL_GetError()});
        return 1;
    };
    defer sdl.SDL_DestroyRenderer(ren);
    const tex = sdl.SDL_CreateTexture(ren, sdl.SDL_PIXELFORMAT_RGB24, sdl.SDL_TEXTUREACCESS_STREAMING, @intCast(dec.info.width), @intCast(dec.info.height)) orelse {
        try err.interface.print("vrestore-gui: could not create a texture: {s}\n", .{sdl.SDL_GetError()});
        return 1;
    };
    defer sdl.SDL_DestroyTexture(tex);

    // パネルの文字のフォント: --font、VRESTORE_FONT、システムのフォントの順
    const font_path = fonts.pick(font_arg orelse init.environ_map.get("VRESTORE_FONT"), io, struct {
        fn f(ioo: Io, candidate: []const u8) bool {
            Io.Dir.cwd().access(ioo, candidate, .{}) catch return false;
            return true;
        }
    }.f);
    if (font_arg != null and font_path == null) try err.interface.print("vrestore-gui: font '{s}' not found; using the built-in digits\n", .{font_arg.?});
    var text = Text.init(ren, font_path, 14);
    // defer は逆順に動く。フォントを閉じてから TTF_Quit する（逆だと TTF_CloseFont が落ちる）
    defer if (text.font != null) sdl.TTF_Quit();
    defer text.deinit();
    app.text = &text;

    defer app.clearRestored();
    if (share_and_exit) {
        // 再生と同じ経路（tickTo）で play_frames 枚ぶん進める
        if (play_frames > 0) _ = try app.tickTo(app.time_sec + @as(f64, @floatFromInt(play_frames)) * app.frame_dur);
        draw(&app, win, ren, tex);
        if (screenshot) |png_path| saveScreenshot(arena, io, ren, png_path) catch |e| {
            try err.interface.print("vrestore-gui: could not save the screenshot '{s}': {s}\n", .{ png_path, @errorName(e) });
            return 1;
        };
        var line_buf: [512]u8 = undefined;
        try out.interface.print("{s}\n", .{app.shareLine(&line_buf)});
        return 0;
    }
    if (detect_and_exit) {
        try app.detect();
        if (restore_too and app.detection != null) {
            try app.restore();
            app.show_provenance = show_prov;
        }
        draw(&app, win, ren, tex);
        if (screenshot) |png_path| saveScreenshot(arena, io, ren, png_path) catch |e| {
            try err.interface.print("vrestore-gui: could not save the screenshot '{s}': {s}\n", .{ png_path, @errorName(e) });
            return 1;
        };
        sdl.SDL_RenderPresent(ren);
        if (app.detection) |d| {
            try detect_roi.writeJson(&out.interface, d);
            if (restore_too) {
                if (app.restored == null) {
                    try err.interface.print("vrestore-gui: {s}\n", .{app.problem[0..app.problem_len]});
                    return 1;
                }
                try out.interface.print("{{\"time_sec\":{d:.3},\"recovered\":{d},\"pixels\":{d},\"coverage\":{d:.4},\"provenance\":", .{ app.time_sec, app.recovered.recovered(), app.recovered.roiPixels(), app.recovered.coverage() });
                try app.recovered.writeJson(&out.interface);
                try out.interface.writeAll("}\n");
            }
            return 0;
        }
        try err.interface.print("vrestore-gui: {s}\n", .{app.problem[0..app.problem_len]});
        return 1;
    }

    var panel_seeking = false;
    var running = true;
    render(&app, win, ren, tex);
    while (running) {
        var ev: sdl.SDL_Event = undefined;
        // 再生中は、次のフレームの時刻までだけイベントを待つ
        const got = if (app.clock.playing)
            sdl.SDL_WaitEventTimeout(&ev, @intFromFloat(@max(1, app.frame_dur * 1000 / 2)))
        else
            sdl.SDL_WaitEvent(&ev);
        var dirty = false;
        if (got != 0) {
            dirty = true;
            const v = viewOf(ren, &app);
            const area = areaOf(v);
            app.panel.info = infoLen(&app) > 0;
            const tw = textWidths(&app);
            switch (ev.type) {
                sdl.SDL_QUIT => running = false,
                sdl.SDL_MOUSEBUTTONDOWN => if (ev.button.button == sdl.SDL_BUTTON_LEFT) {
                    const mx: f32 = @floatFromInt(ev.button.x);
                    const my: f32 = @floatFromInt(ev.button.y);
                    switch (ps.routePress(app.panel, area, tw, mx, my)) {
                        .toggle_play => app.togglePlay(),
                        .skip_back => try app.showAt(app.time_sec - ps.skip_sec),
                        .skip_forward => try app.showAt(app.time_sec + ps.skip_sec),
                        .seek => {
                            panel_seeking = true;
                            try app.showAt(ps.seekToSec(app.panel.seekBar(area, tw), mx, app.duration));
                        },
                        .move_panel => app.panel.beginDrag(area, mx, my),
                        .select => {
                            app.pause();
                            app.selection.begin(v.toFrame(mx, my));
                        },
                        .nothing => dirty = false,
                    }
                },
                sdl.SDL_MOUSEMOTION => {
                    const mx: f32 = @floatFromInt(ev.motion.x);
                    const my: f32 = @floatFromInt(ev.motion.y);
                    if (panel_seeking) {
                        try app.showAt(ps.seekToSec(app.panel.seekBar(area, tw), mx, app.duration));
                    } else if (app.panel.grab != null) {
                        app.panel.drag(area, mx, my);
                    } else if (app.selection.anchor != null) {
                        app.selection.move(v.toFrame(mx, my));
                    } else dirty = false;
                },
                sdl.SDL_MOUSEBUTTONUP => if (ev.button.button == sdl.SDL_BUTTON_LEFT) {
                    if (panel_seeking) {
                        panel_seeking = false;
                    } else if (app.panel.grab != null) {
                        app.panel.endDrag();
                    } else app.selection.end(v.toFrame(@floatFromInt(ev.button.x), @floatFromInt(ev.button.y)));
                },
                sdl.SDL_KEYDOWN => {
                    const shift = (ev.key.keysym.mod & sdl.KMOD_SHIFT) != 0;
                    switch (ev.key.keysym.scancode) {
                        sdl.SDL_SCANCODE_Q => running = false,
                        sdl.SDL_SCANCODE_SPACE => app.togglePlay(),
                        sdl.SDL_SCANCODE_H => app.panel.hidden = !app.panel.hidden,
                        sdl.SDL_SCANCODE_C => {
                            var line_buf: [512]u8 = undefined;
                            const line = app.shareLine(&line_buf);
                            var z: [513]u8 = undefined;
                            @memcpy(z[0..line.len], line);
                            z[line.len] = 0;
                            _ = sdl.SDL_SetClipboardText(@ptrCast(&z));
                            try out.interface.print("{s}\n", .{line});
                            try out.interface.flush();
                            app.setProblem("copied: {s}", .{line});
                        },
                        sdl.SDL_SCANCODE_ESCAPE => {
                            app.clearRestored();
                            app.selection = .{};
                            app.detection = null;
                            app.problem_len = 0;
                        },
                        sdl.SDL_SCANCODE_RETURN, sdl.SDL_SCANCODE_D => {
                            app.pause();
                            app.setProblem("detecting...", .{});
                            render(&app, win, ren, tex);
                            try app.detect();
                        },
                        sdl.SDL_SCANCODE_R => {
                            app.pause();
                            app.setProblem("restoring...", .{});
                            render(&app, win, ren, tex);
                            try app.restore();
                        },
                        sdl.SDL_SCANCODE_B => {
                            if (app.restored != null) app.show_after = !app.show_after;
                        },
                        sdl.SDL_SCANCODE_M => {
                            app.clearRestored();
                            app.motion_model = if (app.motion_model == .translation) .affine else .translation;
                        },
                        sdl.SDL_SCANCODE_F => {
                            app.clearRestored();
                            app.fill = if (app.fill == .none) .harmonic else .none;
                        },
                        sdl.SDL_SCANCODE_P => {
                            if (app.restored != null) {
                                app.show_provenance = !app.show_provenance;
                                app.show_after = true;
                            }
                        },
                        sdl.SDL_SCANCODE_RIGHT => {
                            app.pause();
                            if (shift) try app.showAt(app.time_sec + 1) else try app.step();
                        },
                        sdl.SDL_SCANCODE_LEFT => {
                            app.pause();
                            try app.showAt(app.time_sec - if (shift) 1 else app.frame_dur);
                        },
                        sdl.SDL_SCANCODE_UP => try app.showAt(app.time_sec + 10),
                        sdl.SDL_SCANCODE_DOWN => try app.showAt(app.time_sec - 10),
                        sdl.SDL_SCANCODE_HOME => try app.showAt(0),
                        sdl.SDL_SCANCODE_END => try app.showAt(app.duration),
                        else => dirty = false,
                    }
                },
                sdl.SDL_WINDOWEVENT => {},
                else => dirty = false,
            }
        }
        if (app.clock.playing and try app.tickTo(app.clock.target(sdl.SDL_GetTicks64()))) dirty = true;
        if (dirty) render(&app, win, ren, tex);
    }
    return 0;
}

fn windowWidth(ren: *sdl.SDL_Renderer) f32 {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetRendererOutputSize(ren, &w, &h);
    return @floatFromInt(w);
}

/// 帯を除いた領域にフレームを置いたときの View
fn viewOf(ren: *sdl.SDL_Renderer, app: *const App) state.View {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetRendererOutputSize(ren, &w, &h);
    return state.View.fit(app.dec.info.width, app.dec.info.height, @intCast(@max(1, w)), @intCast(@max(1, h - bar_h)));
}

fn render(app: *App, win: *sdl.SDL_Window, ren: *sdl.SDL_Renderer, tex: *sdl.SDL_Texture) void {
    draw(app, win, ren, tex);
    sdl.SDL_RenderPresent(ren);
}

/// 描画した内容を PNG に保存する（Present の前に読む。後だと中身が決まっていない）
fn saveScreenshot(arena: std.mem.Allocator, io: Io, ren: *sdl.SDL_Renderer, path: []const u8) !void {
    var w: c_int = 0;
    var h: c_int = 0;
    if (sdl.SDL_GetRendererOutputSize(ren, &w, &h) != 0) return error.ReadPixelsFailed;
    const buf = try arena.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 3);
    if (sdl.SDL_RenderReadPixels(ren, null, sdl.SDL_PIXELFORMAT_RGB24, buf.ptr, w * 3) != 0) return error.ReadPixelsFailed;
    const png = try video.encodePng(arena, @intCast(w), @intCast(h), buf);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
}

fn draw(app: *App, win: *sdl.SDL_Window, ren: *sdl.SDL_Renderer, tex: *sdl.SDL_Texture) void {
    const v = viewOf(ren, app);
    const ww = windowWidth(ren);
    _ = sdl.SDL_UpdateTexture(tex, null, app.pixels().ptr, @intCast(app.dec.info.width * 3));
    _ = sdl.SDL_SetRenderDrawColor(ren, 24, 24, 24, 255);
    _ = sdl.SDL_RenderClear(ren);
    _ = sdl.SDL_RenderCopyF(ren, tex, null, &.{ .x = v.x, .y = v.y, .w = v.w, .h = v.h });

    // 選択: シアン。検出結果: reliable なら赤、そうでなければ黄（CLI の frame-overlay.png と同じ色）
    // 検出の枠は選択の枠の 1 段外側に描く。同じ位置に当たっても両方見える
    if (app.selection.dragging() orelse app.selection.rect) |r| drawRect(ren, v, r, .{ 0, 220, 255 }, 1);
    if (app.detection) |d| drawRect(ren, v, .{ .x = @intCast(d.x), .y = @intCast(d.y), .w = @intCast(d.width), .h = @intCast(d.height) }, if (d.reliable) .{ 255, 32, 32 } else .{ 255, 210, 0 }, 3);

    // 下端の帯: 検出の得票率の棒（reliable なら赤、そうでなければ黄。閾値の位置に白い目盛り）
    const by = v.y + v.h;
    fill(ren, .{ .x = 0, .y = by, .w = ww, .h = bar_h }, .{ 48, 48, 48 });
    if (app.detection) |d| {
        const col: [3]u8 = if (d.reliable) .{ 255, 32, 32 } else .{ 255, 210, 0 };
        fill(ren, .{ .x = 0, .y = by + 2, .w = ww * @as(f32, @floatCast(d.confidence)), .h = bar_h - 4 }, col);
        const tick = ww * @as(f32, @floatCast(detect_roi.default_thresholds.min_confidence));
        fill(ren, .{ .x = tick - 1, .y = by, .w = 2, .h = bar_h }, .{ 255, 255, 255 });
    }

    if (ps.panelVisible(app.panel, app.selection.anchor != null)) drawPanel(app, ren, areaOf(v));

    // 窓のタイトルはファイル名だけ。検出・復元の数値はパネルの 3 段目に出す（docs/adr/0009）
    var title_buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&title_buf);
    title(&w, app) catch {};
    title_buf[@min(w.end, title_buf.len - 1)] = 0;
    sdl.SDL_SetWindowTitle(win, @ptrCast(&title_buf));
}

/// 映像を描いている領域（パネルはこの中に収める）
fn areaOf(v: state.View) ps.Box {
    return .{ .x = v.x, .y = v.y, .w = v.w, .h = v.h };
}

fn textWidths(app: *const App) ps.TextWidths {
    const t = app.text orelse return .{ .time = 96 };
    return .{ .time = t.width("00:00:00") };
}

/// パネルの 3 段目に出す 1 行（検出・復元の結果や、操作の案内・エラー）。無ければ長さ 0
fn infoText(app: *const App, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    info(&w, app) catch {};
    return w.buffered();
}

fn infoLen(app: *const App) usize {
    var buf: [256]u8 = undefined;
    return infoText(app, &buf).len;
}

fn info(w: *Io.Writer, app: *const App) !void {
    if (app.problem_len > 0) return w.writeAll(app.problem[0..app.problem_len]);
    if (app.restored != null) {
        try w.print("{s}  restored {d:.1}%", .{ if (app.show_after) "AFTER" else "BEFORE", app.recovered.coverage() * 100 });
        if (app.recovered.counts.get(.spatial_inpainted) > 0) try w.print("  inpainted {d:.1}%", .{app.recovered.fraction(.spatial_inpainted) * 100});
        try w.print("  unrecovered {d:.1}%  {s}/{s}", .{ app.recovered.fraction(.unrecovered) * 100, @tagName(app.motion_model), @tagName(app.fill) });
        return;
    }
    if (app.detection) |d| {
        try w.print("ROI {d},{d} {d}x{d}  confidence {d:.3}  {s}", .{ d.x, d.y, d.width, d.height, d.confidence, if (d.reliable) "RELIABLE" else "NOT RELIABLE" });
        return;
    }
    if (app.selection.rect) |r| return w.print("selected {d},{d} {d}x{d}  Enter: detect", .{ r.x, r.y, r.w, r.h });
}

/// 角の丸い矩形を塗る（三角形の扇で描く）
fn fillRounded(ren: *sdl.SDL_Renderer, b: ps.Box, r: f32, col: sdl.SDL_Color) void {
    const seg = 6;
    var verts: [4 * (seg + 1) + 1]sdl.SDL_Vertex = undefined;
    var idx: [4 * (seg + 1) * 3]c_int = undefined;
    const center: sdl.SDL_FPoint = .{ .x = b.x + b.w / 2, .y = b.y + b.h / 2 };
    verts[0] = .{ .position = center, .color = col, .tex_coord = .{ .x = 0, .y = 0 } };
    const corners = [4][3]f32{
        .{ b.x + b.w - r, b.y + r, -std.math.pi / 2.0 }, // 右上
        .{ b.x + b.w - r, b.y + b.h - r, 0 }, // 右下
        .{ b.x + r, b.y + b.h - r, std.math.pi / 2.0 }, // 左下
        .{ b.x + r, b.y + r, std.math.pi }, // 左上
    };
    var n: usize = 1;
    for (corners) |c| for (0..seg + 1) |k| {
        const ang = c[2] + @as(f32, @floatFromInt(k)) / seg * (std.math.pi / 2.0);
        verts[n] = .{ .position = .{ .x = c[0] + r * @cos(ang), .y = c[1] + r * @sin(ang) }, .color = col, .tex_coord = .{ .x = 0, .y = 0 } };
        n += 1;
    };
    const m = n - 1;
    for (0..m) |k| {
        idx[k * 3] = 0;
        idx[k * 3 + 1] = @intCast(1 + k);
        idx[k * 3 + 2] = @intCast(1 + (k + 1) % m);
    }
    _ = sdl.SDL_RenderGeometry(ren, null, &verts, @intCast(n), &idx, @intCast(m * 3));
}

fn fillCircle(ren: *sdl.SDL_Renderer, cx: f32, cy: f32, r: f32, col: sdl.SDL_Color) void {
    fillRounded(ren, .{ .x = cx - r, .y = cy - r, .w = 2 * r, .h = 2 * r }, r, col);
}

fn triangle(ren: *sdl.SDL_Renderer, p: [3][2]f32, col: sdl.SDL_Color) void {
    var v: [3]sdl.SDL_Vertex = undefined;
    for (p, &v) |q, *vv| vv.* = .{ .position = .{ .x = q[0], .y = q[1] }, .color = col, .tex_coord = .{ .x = 0, .y = 0 } };
    _ = sdl.SDL_RenderGeometry(ren, null, &v, 3, null, 0);
}

/// 映像の上に重ねる操作パネル（QuickTime Player 風）:
///   1 段目: フレーム番号 / 10 秒戻る・再生・10 秒進む、2 段目: 経過時刻 ― シークバー ― 全体の長さ、3 段目: 情報
fn drawPanel(app: *App, ren: *sdl.SDL_Renderer, area: ps.Box) void {
    const text = app.text.?;
    const tw = textWidths(app);
    var info_buf: [256]u8 = undefined;
    const info_line = infoText(app, &info_buf);
    app.panel.info = info_line.len > 0;
    const b = app.panel.box(area);
    _ = sdl.SDL_SetRenderDrawBlendMode(ren, sdl.SDL_BLENDMODE_BLEND);
    defer _ = sdl.SDL_SetRenderDrawBlendMode(ren, sdl.SDL_BLENDMODE_NONE);
    fillRounded(ren, b, ps.Panel.radius, .{ .r = 40, .g = 40, .b = 40, .a = 175 });

    const white: sdl.SDL_Color = .{ .r = 245, .g = 245, .b = 245, .a = 255 };
    // 1 段目: フレーム番号（場面の共有に使う。C でコピー）
    var fbuf: [32]u8 = undefined;
    const fl = app.panel.frameLabel(area);
    text.draw(ps.frameText(&fbuf, app.time_sec, app.fps), fl.x, fl.y, fl.h, .{ 245, 245, 245 }, 170);

    // 10 秒戻る ◀◀ / 再生 ▶・一時停止 ❚❚ / 10 秒進む ▶▶
    const bb = app.panel.backButton(area);
    const cy = bb.y + bb.h / 2;
    triangle(ren, .{ .{ bb.x + bb.w / 2, cy - 7 }, .{ bb.x + bb.w / 2, cy + 7 }, .{ bb.x + 1, cy } }, white);
    triangle(ren, .{ .{ bb.x + bb.w - 1, cy - 7 }, .{ bb.x + bb.w - 1, cy + 7 }, .{ bb.x + bb.w / 2, cy } }, white);
    const fb = app.panel.forwardButton(area);
    triangle(ren, .{ .{ fb.x + 1, cy - 7 }, .{ fb.x + 1, cy + 7 }, .{ fb.x + fb.w / 2, cy } }, white);
    triangle(ren, .{ .{ fb.x + fb.w / 2, cy - 7 }, .{ fb.x + fb.w / 2, cy + 7 }, .{ fb.x + fb.w - 1, cy } }, white);
    const pb = app.panel.playButton(area);
    const pcy = pb.y + pb.h / 2;
    if (app.clock.playing) {
        fillRounded(ren, .{ .x = pb.x + 8, .y = pcy - 11, .w = 6, .h = 22 }, 2, white);
        fillRounded(ren, .{ .x = pb.x + pb.w - 14, .y = pcy - 11, .w = 6, .h = 22 }, 2, white);
    } else {
        triangle(ren, .{ .{ pb.x + 9, pcy - 12 }, .{ pb.x + 9, pcy + 12 }, .{ pb.x + pb.w - 5, pcy } }, white);
    }

    // 2 段目: 経過時刻 ― シークバー ― 全体の長さ
    var ebuf: [32]u8 = undefined;
    var tbuf: [32]u8 = undefined;
    const el = app.panel.elapsedLabel(area, tw);
    const tl = app.panel.totalLabel(area, tw);
    text.draw(ps.clockText(&ebuf, app.time_sec), el.x, el.y, el.h, .{ 245, 245, 245 }, 220);
    text.draw(ps.clockText(&tbuf, app.duration), tl.x, tl.y, tl.h, .{ 245, 245, 245 }, 220);
    const sb = app.panel.seekBar(area, tw);
    const sy = sb.y + sb.h / 2;
    fillRounded(ren, .{ .x = sb.x, .y = sy - 2, .w = sb.w, .h = 4 }, 2, .{ .r = 255, .g = 255, .b = 255, .a = 70 });
    const progress: f32 = if (app.duration > 0) @floatCast(std.math.clamp(app.time_sec / app.duration, 0, 1)) else 0;
    if (progress > 0) fillRounded(ren, .{ .x = sb.x, .y = sy - 2, .w = @max(4, sb.w * progress), .h = 4 }, 2, white);
    fillCircle(ren, sb.x + sb.w * progress, sy, 7, white);

    // 3 段目: 検出・復元の結果や案内（あるときだけ）
    if (info_line.len > 0) {
        const il = app.panel.infoLabel(area);
        text.draw(info_line, il.x, il.y, il.h, .{ 245, 245, 245 }, 190);
    }
}

fn title(w: *Io.Writer, app: *const App) !void {
    try w.print("{s} — vrestore", .{app.video_name});
}

fn drawRect(ren: *sdl.SDL_Renderer, v: state.View, r: state.Rect, col: [3]u8, from: usize) void {
    const s = v.toScreen(r);
    _ = sdl.SDL_SetRenderDrawColor(ren, col[0], col[1], col[2], 255);
    for (from..from + 2) |k| {
        const o: f32 = @floatFromInt(k);
        _ = sdl.SDL_RenderDrawRectF(ren, &.{ .x = s[0] - o, .y = s[1] - o, .w = s[2] + 2 * o, .h = s[3] + 2 * o });
    }
}

fn fill(ren: *sdl.SDL_Renderer, r: sdl.SDL_FRect, col: [3]u8) void {
    _ = sdl.SDL_SetRenderDrawColor(ren, col[0], col[1], col[2], 255);
    _ = sdl.SDL_RenderFillRectF(ren, &r);
}

fn parseRect(s: []const u8) ?state.Rect {
    const r = compare.parseRect(s) orelse return null;
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

fn badArg(err: *Io.Writer, why: []const u8, arg: []const u8) !u8 {
    try err.print("vrestore-gui: {s}: '{s}'\n\n{s}", .{ why, arg, usage });
    return 2;
}
