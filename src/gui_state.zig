//! GUI の状態と座標計算。SDL に依存しないので、ここはユニットテストで確かめる。
//! 描画とイベントの読み取りは gui.zig（薄い層）が持つ。検出は detect_roi.detectInVideo を呼ぶだけ。

const std = @import("std");

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// フレームを窓の中にアスペクト比を保って置いたときの位置と倍率（レターボックス）。
pub const View = struct {
    /// 窓の中でフレームを描く左上と大きさ（画面座標）
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// フレーム 1 px が画面で何 px か
    scale: f32,
    frame_w: u32,
    frame_h: u32,

    pub fn fit(frame_w: u32, frame_h: u32, area_w: u32, area_h: u32) View {
        const fw: f32 = @floatFromInt(frame_w);
        const fh: f32 = @floatFromInt(frame_h);
        const aw: f32 = @floatFromInt(area_w);
        const ah: f32 = @floatFromInt(area_h);
        const scale = @min(aw / fw, ah / fh);
        return .{
            .x = (aw - fw * scale) / 2,
            .y = (ah - fh * scale) / 2,
            .w = fw * scale,
            .h = fh * scale,
            .scale = scale,
            .frame_w = frame_w,
            .frame_h = frame_h,
        };
    }

    /// 画面座標をフレームの画素座標にする。フレームの外は端に寄せる
    pub fn toFrame(v: View, sx: f32, sy: f32) [2]u32 {
        const fx = std.math.clamp((sx - v.x) / v.scale, 0, @as(f32, @floatFromInt(v.frame_w)));
        const fy = std.math.clamp((sy - v.y) / v.scale, 0, @as(f32, @floatFromInt(v.frame_h)));
        return .{ @intFromFloat(@floor(fx)), @intFromFloat(@floor(fy)) };
    }

    /// フレームの矩形を画面の矩形にする（描画用）
    pub fn toScreen(v: View, r: Rect) [4]f32 {
        return .{
            v.x + @as(f32, @floatFromInt(r.x)) * v.scale,
            v.y + @as(f32, @floatFromInt(r.y)) * v.scale,
            @as(f32, @floatFromInt(r.w)) * v.scale,
            @as(f32, @floatFromInt(r.h)) * v.scale,
        };
    }

    pub fn contains(v: View, sx: f32, sy: f32) bool {
        return sx >= v.x and sx < v.x + v.w and sy >= v.y and sy < v.y + v.h;
    }
};

/// マウスドラッグでの矩形選択。座標はフレームの画素
pub const Selection = struct {
    anchor: ?[2]u32 = null,
    current: [2]u32 = .{ 0, 0 },
    /// 確定した選択。ドラッグ中は前回の確定値のまま
    rect: ?Rect = null,

    pub fn begin(s: *Selection, p: [2]u32) void {
        s.anchor = p;
        s.current = p;
    }

    pub fn move(s: *Selection, p: [2]u32) void {
        if (s.anchor != null) s.current = p;
    }

    /// ドラッグ中の矩形（描画用）
    pub fn dragging(s: Selection) ?Rect {
        const a = s.anchor orelse return null;
        return normalize(a, s.current);
    }

    /// ボタンを離した。幅か高さが 0 の選択（クリックだけ）は捨てて、前の選択を残す
    pub fn end(s: *Selection, p: [2]u32) void {
        const a = s.anchor orelse return;
        s.anchor = null;
        const r = normalize(a, p);
        if (r.w > 0 and r.h > 0) s.rect = r;
    }
};

/// 2 点から矩形を作る。どちら向きにドラッグしても同じ矩形になる
pub fn normalize(a: [2]u32, b: [2]u32) Rect {
    const x0 = @min(a[0], b[0]);
    const y0 = @min(a[1], b[1]);
    return .{ .x = x0, .y = y0, .w = @max(a[0], b[0]) - x0, .h = @max(a[1], b[1]) - y0 };
}

/// タイムライン（窓の下端の帯）上の横位置から時刻を出す
pub fn timelineToSec(sx: f32, bar_x: f32, bar_w: f32, duration: f64) f64 {
    const t = std.math.clamp((sx - bar_x) / bar_w, 0, 1);
    return @as(f64, t) * duration;
}

/// RGB24 のフレームから矩形を切り出す（参照画像を作る）
pub fn crop(gpa: std.mem.Allocator, rgb: []const u8, frame_w: u32, r: Rect) ![]u8 {
    const row = @as(usize, r.w) * 3;
    const out = try gpa.alloc(u8, row * r.h);
    for (0..r.h) |j| @memcpy(out[j * row ..][0..row], rgb[((r.y + j) * frame_w + r.x) * 3 ..][0..row]);
    return out;
}

// ---- tests -------------------------------------------------------------------

test "gui: fit letterboxes a wide frame into a tall window, and maps back" {
    // 1920x1080 を 800x800 に置くと、幅に合わせて 800x450、上下に 175 ずつ余白
    const v = View.fit(1920, 1080, 800, 800);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 175), v.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 800), v.w, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 450), v.h, 1e-3);
    // 画面の中央はフレームの中央
    try std.testing.expectEqual([2]u32{ 960, 540 }, v.toFrame(400, 400));
    // 余白をクリックしてもフレームの端に寄る
    try std.testing.expectEqual([2]u32{ 0, 0 }, v.toFrame(-10, 10));
    try std.testing.expectEqual([2]u32{ 1920, 1080 }, v.toFrame(900, 790));
    try std.testing.expect(!v.contains(400, 100));
    try std.testing.expect(v.contains(400, 400));
}

test "gui: toScreen is the inverse of toFrame for the corners of a rect" {
    const v = View.fit(640, 360, 1280, 720); // ちょうど 2 倍
    const s = v.toScreen(.{ .x = 10, .y = 20, .w = 100, .h = 50 });
    try std.testing.expectEqual([4]f32{ 20, 40, 200, 100 }, s);
    try std.testing.expectEqual([2]u32{ 10, 20 }, v.toFrame(s[0], s[1]));
    try std.testing.expectEqual([2]u32{ 110, 70 }, v.toFrame(s[0] + s[2], s[1] + s[3]));
}

test "gui: selection works in any drag direction and ignores a plain click" {
    var s: Selection = .{};
    s.begin(.{ 300, 200 });
    s.move(.{ 100, 250 });
    try std.testing.expectEqual(Rect{ .x = 100, .y = 200, .w = 200, .h = 50 }, s.dragging().?);
    s.end(.{ 100, 150 });
    try std.testing.expectEqual(Rect{ .x = 100, .y = 150, .w = 200, .h = 50 }, s.rect.?);
    try std.testing.expectEqual(@as(?Rect, null), s.dragging());

    // クリックだけ（大きさ 0）は前の選択を消さない
    s.begin(.{ 5, 5 });
    s.end(.{ 5, 5 });
    try std.testing.expectEqual(Rect{ .x = 100, .y = 150, .w = 200, .h = 50 }, s.rect.?);
}

test "gui: timeline maps position to time and clamps" {
    try std.testing.expectEqual(@as(f64, 0), timelineToSec(-5, 10, 100, 60));
    try std.testing.expectApproxEqAbs(@as(f64, 30), timelineToSec(60, 10, 100, 60), 1e-6);
    try std.testing.expectEqual(@as(f64, 60), timelineToSec(500, 10, 100, 60));
}

test "gui: crop cuts the selected pixels" {
    const gpa = std.testing.allocator;
    // 4x3 の画像、画素 i の値は (i, i, i)
    var rgb: [4 * 3 * 3]u8 = undefined;
    for (0..12) |i| rgb[i * 3 ..][0..3].* = .{ @intCast(i), @intCast(i), @intCast(i) };
    const c = try crop(gpa, &rgb, 4, .{ .x = 1, .y = 1, .w = 2, .h = 2 });
    defer gpa.free(c);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 5, 6, 6, 6, 9, 9, 9, 10, 10, 10 }, c);
}
