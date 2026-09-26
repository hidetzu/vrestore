//! 動画プレイヤーとしての UI の状態と計算。SDL に依存しないので、ここはユニットテストで確かめる。
//! 描画とイベントの読み取りは gui.zig（薄い層）が持つ。
//!
//! - 操作パネル: 映像の上に重ねる。ドラッグで動かせ、映像の表示領域の外へは出ない
//! - 入力の振り分け: パネルの上の操作は ROI の選択にならない。ROI を選んでいる間はパネルを隠す
//! - 再生の時計: 経過時間から、何フレーム進めるか（大きく遅れたら seek に切り替える）
//! - 時刻・フレーム番号の表示と、場面を共有するための文字列

const std = @import("std");

/// 画面座標の矩形（浮動小数）
pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(b: Box, px: f32, py: f32) bool {
        return px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h;
    }
};

/// パネルの上のどこか
pub const Part = enum { none, play_button, seek_bar, body };

/// 映像の上に重ねる操作パネル。位置は画面座標で持ち、映像の表示領域（`area`）の中に押し込む
pub const Panel = struct {
    x: f32,
    y: f32,
    /// ドラッグ中なら、掴んだ点のパネル左上からの位置
    grab: ?[2]f32 = null,
    hidden: bool = false,
    /// 一度も動かしていなければ、映像の下寄り中央に置き続ける（窓の大きさが変わっても追従する）
    placed: bool = false,

    pub const height: f32 = 56;
    pub const max_width: f32 = 640;
    pub const margin: f32 = 12;
    pub const button: f32 = 36;
    pub const pad: f32 = 10;

    /// パネルの大きさ: 映像の幅に合わせて縮む（余白を残す）
    pub fn size(area: Box) [2]f32 {
        return .{ @max(160, @min(max_width, area.w - 2 * margin)), height };
    }

    /// 既定の位置（映像の下寄り中央）
    pub fn home(area: Box) [2]f32 {
        const s = size(area);
        return .{ area.x + (area.w - s[0]) / 2, area.y + area.h - s[1] - margin };
    }

    /// 現在の枠。映像の外に出ていれば押し戻したもの
    pub fn box(p: Panel, area: Box) Box {
        const s = size(area);
        const pos = if (p.placed) [2]f32{ p.x, p.y } else home(area);
        return .{ .x = clampAxis(pos[0], area.x, area.w, s[0]), .y = clampAxis(pos[1], area.y, area.h, s[1]), .w = s[0], .h = s[1] };
    }

    pub fn playButton(p: Panel, area: Box) Box {
        const b = p.box(area);
        return .{ .x = b.x + pad, .y = b.y + (b.h - button) / 2, .w = button, .h = button };
    }

    /// シークバー（再生ボタンの右、上半分）
    pub fn seekBar(p: Panel, area: Box) Box {
        const b = p.box(area);
        const x0 = b.x + pad + button + pad;
        return .{ .x = x0, .y = b.y + 10, .w = @max(10, b.x + b.w - pad - x0), .h = 14 };
    }

    /// 時刻とフレーム番号の文字（シークバーの下）
    pub fn label(p: Panel, area: Box) Box {
        const s = p.seekBar(area);
        return .{ .x = s.x, .y = s.y + s.h + 6, .w = s.w, .h = 14 };
    }

    pub fn hit(p: Panel, area: Box, px: f32, py: f32) Part {
        if (p.hidden or !p.box(area).contains(px, py)) return .none;
        if (p.playButton(area).contains(px, py)) return .play_button;
        // シークバーは上下に少し広く取って掴みやすくする
        const s = p.seekBar(area);
        if ((Box{ .x = s.x, .y = s.y - 6, .w = s.w, .h = s.h + 12 }).contains(px, py)) return .seek_bar;
        return .body;
    }

    pub fn beginDrag(p: *Panel, area: Box, px: f32, py: f32) void {
        const b = p.box(area);
        p.grab = .{ px - b.x, py - b.y };
    }

    pub fn drag(p: *Panel, area: Box, px: f32, py: f32) void {
        const g = p.grab orelse return;
        const s = size(area);
        p.x = clampAxis(px - g[0], area.x, area.w, s[0]);
        p.y = clampAxis(py - g[1], area.y, area.h, s[1]);
        p.placed = true;
    }

    pub fn endDrag(p: *Panel) void {
        p.grab = null;
    }
};

/// 長さ `len` のものを、`lo` から幅 `span` の中に収める。入りきらなければ左（上）に寄せる
fn clampAxis(v: f32, lo: f32, span: f32, len: f32) f32 {
    const hi = lo + span - len;
    if (hi < lo) return lo;
    return std.math.clamp(v, lo, hi);
}

/// シークバーの横位置から時刻
pub fn seekToSec(bar: Box, px: f32, duration: f64) f64 {
    const t = std.math.clamp((px - bar.x) / bar.w, 0, 1);
    return @as(f64, t) * duration;
}

// ---- 入力の振り分け ----------------------------------------------------------

/// マウスのボタンを押したとき、何をするか
pub const Press = enum {
    /// ROI の選択を始める（映像の上、パネルの外）
    select,
    toggle_play,
    /// シークバーを押した・ドラッグし始めた
    seek,
    /// パネルを動かし始めた
    move_panel,
    /// 映像の外（何もしない。下端の帯は gui.zig が扱う）
    nothing,
};

/// 押した位置から、何をするかを決める。パネルの上なら ROI の選択は始めない
pub fn routePress(p: Panel, area: Box, px: f32, py: f32) Press {
    return switch (p.hit(area, px, py)) {
        .play_button => .toggle_play,
        .seek_bar => .seek,
        .body => .move_panel,
        .none => if (area.contains(px, py)) .select else .nothing,
    };
}

/// パネルを描くか。ROI を選んでいる間（ドラッグ中）は隠して、下にある映像を見えるようにする
pub fn panelVisible(p: Panel, selecting: bool) bool {
    return !p.hidden and !selecting;
}

// ---- 再生の時計 --------------------------------------------------------------

pub const Clock = struct {
    playing: bool = false,
    /// 再生を始めた（または最後に合わせた）時の壁時計（ms）と動画の時刻（秒）
    anchor_ms: u64 = 0,
    anchor_sec: f64 = 0,

    pub fn play(c: *Clock, now_ms: u64, at_sec: f64) void {
        c.playing = true;
        c.anchor_ms = now_ms;
        c.anchor_sec = at_sec;
    }

    pub fn pause(c: *Clock) void {
        c.playing = false;
    }

    /// 今、表示しているべき動画の時刻
    pub fn target(c: Clock, now_ms: u64) f64 {
        if (!c.playing) return c.anchor_sec;
        return c.anchor_sec + @as(f64, @floatFromInt(now_ms -| c.anchor_ms)) / 1000;
    }
};

/// 表示中のフレームの時刻 `shown` から、`target` まで進めるにはどうするか
pub const Advance = union(enum) {
    /// まだ次のフレームの時刻ではない
    wait,
    /// 次のフレームを n 枚読む（最後の 1 枚だけ表示すればよい）
    frames: u32,
    /// 大きく遅れた（または戻った）ので、その時刻へ seek する
    seek: f64,
};

/// 1 秒以上遅れたら、読み進めるより seek の方が速い
pub const max_catch_up_sec = 1.0;

pub fn advance(shown: f64, target_sec: f64, frame_dur: f64) Advance {
    const lag = target_sec - shown;
    if (lag < 0) return if (lag < -frame_dur) .{ .seek = target_sec } else .wait;
    if (lag > max_catch_up_sec) return .{ .seek = target_sec };
    // 次のフレームの表示時刻（shown + frame_dur）に達した枚数だけ進める。丸めの誤差で取りこぼさないよう少し余裕を見る
    const n: u32 = @intFromFloat(@floor(lag / frame_dur + 1e-6));
    return if (n == 0) .wait else .{ .frames = n };
}

// ---- 時刻・フレーム番号 -------------------------------------------------------

/// 動画の時刻からフレーム番号（0 始まり）。一定のフレームレートを仮定する
pub fn frameIndex(sec: f64, fps: f64) u64 {
    return @intFromFloat(@max(0, @round(sec * fps)));
}

/// フレーム番号から時刻（`--frame` で開くとき）
pub fn frameToSec(frame: u64, fps: f64) f64 {
    return @as(f64, @floatFromInt(frame)) / fps;
}

/// "1:02:03.456"（1 時間未満なら "2:03.456"）
pub fn formatTime(buf: []u8, sec: f64, millis: bool) []const u8 {
    const total_ms: u64 = @intFromFloat(@max(0, @round(sec * 1000)));
    const h = total_ms / 3_600_000;
    const m = (total_ms / 60_000) % 60;
    const s = (total_ms / 1000) % 60;
    const ms = total_ms % 1000;
    return (if (h > 0)
        (if (millis) std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>3}", .{ h, m, s, ms }) else std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }))
    else
        (if (millis) std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d:0>3}", .{ m, s, ms }) else std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }))) catch buf[0..0];
}

/// パネルに出す文字: "2:03.456 / 1:57:22  #3689"
pub fn panelText(buf: []u8, sec: f64, duration: f64, fps: f64) []const u8 {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} / {s}  #{d}", .{ formatTime(&a, sec, true), formatTime(&b, duration, false), frameIndex(sec, fps) }) catch buf[0..0];
}

/// 場面を共有するための 1 行: "A.mp4 t=123.456 frame=3700"。
/// `vrestore-gui --at <t>` か `--frame <n>` で同じ場面を開ける
pub fn shareLine(buf: []u8, video_name: []const u8, sec: f64, fps: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{s} t={d:.3} frame={d}", .{ video_name, sec, frameIndex(sec, fps) }) catch buf[0..0];
}

// ---- tests -------------------------------------------------------------------

const area640: Box = .{ .x = 0, .y = 0, .w = 640, .h = 360 };

test "player: the panel starts at the bottom centre and stays inside the video when dragged" {
    var p: Panel = .{ .x = 0, .y = 0 };
    const b0 = p.box(area640);
    try std.testing.expectEqual(@as(f32, 616), b0.w); // 640 - 2 * 12
    try std.testing.expectEqual(@as(f32, 12), b0.x);
    try std.testing.expectEqual(@as(f32, 360 - 56 - 12), b0.y);

    // 掴んで右上へ大きく動かすと、映像の端で止まる
    p.beginDrag(area640, b0.x + 300, b0.y + 30);
    p.drag(area640, 5000, -5000);
    p.endDrag();
    const b1 = p.box(area640);
    try std.testing.expectEqual(@as(f32, 640 - 616), b1.x);
    try std.testing.expectEqual(@as(f32, 0), b1.y);

    // 掴んだ点とパネルの位置の関係は保たれる
    p.beginDrag(area640, b1.x + 100, b1.y + 20);
    p.drag(area640, b1.x + 100 - 10, b1.y + 20 + 50);
    try std.testing.expectEqual(@as(f32, b1.x - 10), p.box(area640).x);
    try std.testing.expectEqual(@as(f32, b1.y + 50), p.box(area640).y);
}

test "player: the panel is pushed back inside when the video area shrinks" {
    var p: Panel = .{ .x = 0, .y = 0 };
    p.beginDrag(area640, 20, 300);
    p.drag(area640, 600, 340);
    const small: Box = .{ .x = 100, .y = 50, .w = 320, .h = 180 };
    const b = p.box(small);
    try std.testing.expect(b.x >= small.x and b.x + b.w <= small.x + small.w);
    try std.testing.expect(b.y >= small.y and b.y + b.h <= small.y + small.h);
}

test "player: presses on the panel never start an ROI selection" {
    const p: Panel = .{ .x = 0, .y = 0 };
    const pb = p.playButton(area640);
    const sb = p.seekBar(area640);
    const b = p.box(area640);
    try std.testing.expectEqual(Press.toggle_play, routePress(p, area640, pb.x + 5, pb.y + 5));
    try std.testing.expectEqual(Press.seek, routePress(p, area640, sb.x + sb.w / 2, sb.y + 2));
    try std.testing.expectEqual(Press.move_panel, routePress(p, area640, b.x + b.w - 3, b.y + b.h - 3));
    try std.testing.expectEqual(Press.select, routePress(p, area640, 100, 50));
    try std.testing.expectEqual(Press.nothing, routePress(p, area640, 700, 50));
    // パネルを隠していれば、同じ位置でも ROI の選択になる
    const hidden: Panel = .{ .x = 0, .y = 0, .hidden = true };
    try std.testing.expectEqual(Press.select, routePress(hidden, area640, pb.x + 5, pb.y + 5));
    // ROI を選んでいる間はパネルを描かない
    try std.testing.expect(!panelVisible(p, true));
    try std.testing.expect(panelVisible(p, false));
}

test "player: seek bar maps position to time" {
    const bar: Box = .{ .x = 100, .y = 0, .w = 200, .h = 10 };
    try std.testing.expectEqual(@as(f64, 0), seekToSec(bar, 50, 60));
    try std.testing.expectApproxEqAbs(@as(f64, 30), seekToSec(bar, 200, 60), 1e-9);
    try std.testing.expectEqual(@as(f64, 60), seekToSec(bar, 900, 60));
}

test "player: the clock advances with wall time only while playing" {
    var c: Clock = .{};
    c.play(1000, 5.0);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), c.target(2500), 1e-9);
    c.pause();
    c.anchor_sec = c.target(2500);
    try std.testing.expectEqual(@as(f64, 5.0), c.target(9000)); // 止めたら進まない（anchor は呼ぶ側が合わせる）
}

test "player: advance reads the frames that are due, and seeks when far behind" {
    const fd = 0.1; // 10 fps
    try std.testing.expectEqual(Advance.wait, advance(1.0, 1.05, fd));
    try std.testing.expectEqual(Advance{ .frames = 1 }, advance(1.0, 1.1, fd));
    try std.testing.expectEqual(Advance{ .frames = 3 }, advance(1.0, 1.35, fd));
    try std.testing.expectEqual(Advance{ .seek = 3.0 }, advance(1.0, 3.0, fd));
    // 戻った（シークバーで前へ）
    try std.testing.expectEqual(Advance{ .seek = 0.5 }, advance(1.0, 0.5, fd));
}

test "player: time, frame number and the share line" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2:03.456", formatTime(&buf, 123.456, true));
    try std.testing.expectEqualStrings("1:57:22", formatTime(&buf, 7042.0, false));
    try std.testing.expectEqualStrings("0:00.000", formatTime(&buf, 0, true));
    try std.testing.expectEqual(@as(u64, 3700), frameIndex(123.333, 30));
    try std.testing.expectApproxEqAbs(@as(f64, 123.3333), frameToSec(3700, 30), 1e-3);
    try std.testing.expectEqualStrings("2:03.456 / 1:57:22  #3704", panelText(&buf, 123.456, 7042.0, 30));
    try std.testing.expectEqualStrings("A.mp4 t=123.456 frame=3704", shareLine(&buf, "A.mp4", 123.456, 30));
}
