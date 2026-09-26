//! vrestore-gui: 動画のフレームを見ながらウォーターマークの範囲を矩形で選び、ROI 検出にかける最小の UI。
//!
//! ここは SDL2 でイベントを読んで描くだけの薄い層。座標計算と選択は gui_state.zig、
//! 検出は detect_roi.detectInVideo（CLI の detect-roi と同じ入口）を呼ぶ。検出のロジックはここに書かない
//! （docs/adr/0004）。
//!
//! 操作:
//!   ドラッグ（フレーム上）   ウォーターマークの範囲を選ぶ
//!   Enter / D                選んだ範囲を参照画像にして検出する
//!   ← / →                    1 フレーム戻る / 進む（Shift で 1 秒、↑ / ↓ で 10 秒）
//!   Home / End               先頭 / 末尾
//!   クリック・ドラッグ（下の帯）  その時刻へ移動
//!   Esc                      選択と検出結果を消す
//!   Q / 窓を閉じる           終了

const std = @import("std");
const Io = std.Io;
const video = @import("video.zig");
const roi = @import("roi.zig");
const detect_roi = @import("detect_roi.zig");
const state = @import("gui_state.zig");
const compare = @import("compare.zig");

const sdl = @cImport({
    @cInclude("SDL.h");
});

const usage =
    \\usage: vrestore-gui [--at <sec>] [--select x,y,w,h --detect-and-exit] <video>
    \\
    \\Drag over the watermark, then press Enter to find where it is fixed in the video.
    \\  --at <sec>              start at this time
    \\  --select x,y,w,h        start with this selection (frame pixels)
    \\  --detect-and-exit       run the detection on --select once, print the JSON and exit
    \\                          (the same path as pressing Enter; used by the tests)
    \\  --screenshot <png>      with --detect-and-exit, also save what the window shows
    \\
;

/// 下端の帯（タイムラインと検出結果の表示）の高さ
const bar_h = 28;

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
    /// 検出できなかったときの理由（窓のタイトルに出す）
    problem: [256]u8 = undefined,
    problem_len: usize = 0,

    fn showAt(app: *App, sec: f64) !void {
        const t = std.math.clamp(sec, 0, @max(0, app.duration - app.frame_dur));
        try app.dec.seek(t);
        if (try app.dec.next(app.rgb)) |f| app.time_sec = f.time_sec;
    }

    fn step(app: *App) !void {
        // 1 フレーム進むのは seek せずに次を読むだけ
        if (try app.dec.next(app.rgb)) |f| app.time_sec = f.time_sec;
    }

    /// 選択範囲を参照画像にして検出する。Enter と --detect-and-exit はどちらもここを通る
    fn detect(app: *App) !void {
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
    var screenshot: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--detect-and-exit")) {
            detect_and_exit = true;
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
        .duration = dec.info.duration_sec orelse 0,
        .frame_dur = 1 / fps,
    };
    try app.showAt(at);
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

    if (detect_and_exit) {
        try app.detect();
        draw(&app, win, ren, tex);
        if (screenshot) |png_path| saveScreenshot(arena, io, ren, png_path) catch |e| {
            try err.interface.print("vrestore-gui: could not save the screenshot '{s}': {s}\n", .{ png_path, @errorName(e) });
            return 1;
        };
        sdl.SDL_RenderPresent(ren);
        if (app.detection) |d| {
            try detect_roi.writeJson(&out.interface, d);
            return 0;
        }
        try err.interface.print("vrestore-gui: {s}\n", .{app.problem[0..app.problem_len]});
        return 1;
    }

    var scrubbing = false;
    var running = true;
    render(&app, win, ren, tex);
    while (running) {
        var ev: sdl.SDL_Event = undefined;
        if (sdl.SDL_WaitEvent(&ev) == 0) break;
        var dirty = true;
        const v = viewOf(ren, &app);
        switch (ev.type) {
            sdl.SDL_QUIT => running = false,
            sdl.SDL_MOUSEBUTTONDOWN => if (ev.button.button == sdl.SDL_BUTTON_LEFT) {
                const mx: f32 = @floatFromInt(ev.button.x);
                const my: f32 = @floatFromInt(ev.button.y);
                if (my >= v.y + v.h) {
                    scrubbing = true;
                    try app.showAt(state.timelineToSec(mx, 0, windowWidth(ren), app.duration));
                } else app.selection.begin(v.toFrame(mx, my));
            },
            sdl.SDL_MOUSEMOTION => {
                const mx: f32 = @floatFromInt(ev.motion.x);
                const my: f32 = @floatFromInt(ev.motion.y);
                if (scrubbing) {
                    try app.showAt(state.timelineToSec(mx, 0, windowWidth(ren), app.duration));
                } else if (app.selection.anchor != null) {
                    app.selection.move(v.toFrame(mx, my));
                } else dirty = false;
            },
            sdl.SDL_MOUSEBUTTONUP => if (ev.button.button == sdl.SDL_BUTTON_LEFT) {
                if (scrubbing) {
                    scrubbing = false;
                } else app.selection.end(v.toFrame(@floatFromInt(ev.button.x), @floatFromInt(ev.button.y)));
            },
            sdl.SDL_KEYDOWN => {
                const shift = (ev.key.keysym.mod & sdl.KMOD_SHIFT) != 0;
                switch (ev.key.keysym.scancode) {
                    sdl.SDL_SCANCODE_Q => running = false,
                    sdl.SDL_SCANCODE_ESCAPE => {
                        app.selection = .{};
                        app.detection = null;
                        app.problem_len = 0;
                    },
                    sdl.SDL_SCANCODE_RETURN, sdl.SDL_SCANCODE_D => {
                        sdl.SDL_SetWindowTitle(win, "vrestore-gui | detecting...");
                        try app.detect();
                    },
                    sdl.SDL_SCANCODE_RIGHT => if (shift) try app.showAt(app.time_sec + 1) else try app.step(),
                    sdl.SDL_SCANCODE_LEFT => try app.showAt(app.time_sec - if (shift) 1 else app.frame_dur),
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
    _ = sdl.SDL_UpdateTexture(tex, null, app.rgb.ptr, @intCast(app.dec.info.width * 3));
    _ = sdl.SDL_SetRenderDrawColor(ren, 24, 24, 24, 255);
    _ = sdl.SDL_RenderClear(ren);
    _ = sdl.SDL_RenderCopyF(ren, tex, null, &.{ .x = v.x, .y = v.y, .w = v.w, .h = v.h });

    // 選択: シアン。検出結果: reliable なら赤、そうでなければ黄（CLI の frame-overlay.png と同じ色）
    // 検出の枠は選択の枠の 1 段外側に描く。同じ位置に当たっても両方見える
    if (app.selection.dragging() orelse app.selection.rect) |r| drawRect(ren, v, r, .{ 0, 220, 255 }, 1);
    if (app.detection) |d| drawRect(ren, v, .{ .x = @intCast(d.x), .y = @intCast(d.y), .w = @intCast(d.width), .h = @intCast(d.height) }, if (d.reliable) .{ 255, 32, 32 } else .{ 255, 210, 0 }, 3);

    // 下端の帯: 上半分がタイムライン、下半分が得票率の棒（閾値の位置に白い目盛り）
    const by = v.y + v.h;
    fill(ren, .{ .x = 0, .y = by, .w = ww, .h = bar_h }, .{ 48, 48, 48 });
    const progress: f32 = if (app.duration > 0) @floatCast(app.time_sec / app.duration) else 0;
    fill(ren, .{ .x = 0, .y = by + 2, .w = ww * progress, .h = bar_h / 2 - 3 }, .{ 120, 160, 220 });
    if (app.detection) |d| {
        const col: [3]u8 = if (d.reliable) .{ 255, 32, 32 } else .{ 255, 210, 0 };
        fill(ren, .{ .x = 0, .y = by + bar_h / 2 + 1, .w = ww * @as(f32, @floatCast(d.confidence)), .h = bar_h / 2 - 3 }, col);
        const tick = ww * @as(f32, @floatCast(detect_roi.default_thresholds.min_confidence));
        fill(ren, .{ .x = tick - 1, .y = by + bar_h / 2, .w = 2, .h = bar_h / 2 }, .{ 255, 255, 255 });
    }

    // 数値は窓のタイトルに出す（SDL2 には文字を描く機能が無い。docs/adr/0004）
    var title_buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&title_buf);
    title(&w, app) catch {};
    title_buf[@min(w.end, title_buf.len - 1)] = 0;
    sdl.SDL_SetWindowTitle(win, @ptrCast(&title_buf));
}

fn title(w: *Io.Writer, app: *const App) !void {
    try w.print("vrestore-gui | {d:.3}s / {d:.1}s", .{ app.time_sec, app.duration });
    if (app.selection.rect) |r| try w.print(" | selected {d},{d} {d}x{d}", .{ r.x, r.y, r.w, r.h });
    if (app.detection) |d| {
        try w.print(" | ROI {d},{d} {d}x{d} confidence {d:.3} margin ", .{ d.x, d.y, d.width, d.height, d.confidence });
        if (d.margin) |m| try w.print("{d:.3}", .{m}) else try w.writeAll("-");
        try w.writeAll(if (d.reliable) " RELIABLE" else " NOT RELIABLE");
        var it = d.reasons.iterator();
        while (it.next()) |r| try w.print(" ({s})", .{@tagName(r)});
    } else if (app.problem_len > 0) {
        try w.print(" | {s}", .{app.problem[0..app.problem_len]});
    } else if (app.selection.rect != null) {
        try w.writeAll(" | Enter: detect");
    } else {
        try w.writeAll(" | drag over the watermark");
    }
}

/// 矩形の外側、`from` px 目から 2 px 幅の枠（内側のウォーターマークを隠さない）
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
