//! Temporal Recovery の debug の可視化（`restore --debug`、docs/adr/0017）。
//!
//! 1 フレームを横に 2 つ並べた画像にする:
//! - 左: 出力に、画素の扱いの色を 50% で重ねる。緑 = 別のフレームから戻した（temporal_real）、
//!   赤 = 候補はあったが auto の条件を通らず推測で埋めた、青 = 候補が無く推測で埋めた、マゼンタ = 埋めていない
//! - 右: 入力を暗くし、戻した画素に「どの前後のフレームから借りたか」の色を塗る。過去 = 青系、未来 = 橙系で、
//!   窓の端（遠くのフレーム）ほど明るい。灰色 = 不採用
//! どちらにも ROI の枠を白で描く。
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;
const temporal = @import("temporal.zig");

pub const accepted_color = [3]u8{ 0, 220, 0 };
pub const rejected_color = [3]u8{ 255, 40, 40 };
pub const guessed_color = [3]u8{ 60, 120, 255 };
pub const unrecovered_color = [3]u8{ 255, 0, 255 };
pub const rejected_source_color = [3]u8{ 150, 150, 150 };
const border = [3]u8{ 255, 255, 255 };

/// フレームの差 `dt`（負 = 過去、正 = 未来）を色にする。`window` は窓の片側の枚数
pub fn sourceColor(dt: i16, window: usize) [3]u8 {
    const a: f32 = @min(1, @as(f32, @floatFromInt(@abs(dt))) / @as(f32, @floatFromInt(@max(1, window))));
    const v: u8 = @intFromFloat(80 + 175 * a);
    return if (dt < 0) .{ 40, v, 255 } else .{ 255, v, 40 };
}

/// `dst`（幅 2w、RGB24）に描く。`area` は推測で埋める範囲（マスクの範囲、無ければ ROI）で、ROI を含む。
/// `detail` は ROI の画素ごと（temporal.recoverFrame）
pub fn render(dst: []u8, w: u32, h: u32, input: []const u8, output: []const u8, prov: []const Provenance, roi: temporal.Rect, area: temporal.Rect, detail: []const temporal.Detail, window: usize) void {
    std.debug.assert(dst.len == @as(usize, w) * 2 * h * 3);
    const dw: usize = @as(usize, w) * 2;
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        const l = (y * dw + x) * 3;
        const r = (y * dw + w + x) * 3;
        for (0..3) |c| {
            dst[l + c] = output[i * 3 + c];
            dst[r + c] = @intCast(@as(u16, input[i * 3 + c]) * 35 / 100);
        }
        const in_area = x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h;
        if (!in_area) continue;
        const in_roi = x >= roi.x and x < roi.x + roi.w and y >= roi.y and y < roi.y + roi.h;
        const d: temporal.Detail = if (in_roi) detail[(y - roi.y) * roi.w + (x - roi.x)] else .{};
        const tint: ?[3]u8 = switch (prov[i]) {
            .temporal_real => accepted_color,
            .spatial_inpainted => if (d.class == .rejected) rejected_color else guessed_color,
            .unrecovered => unrecovered_color,
            else => null,
        };
        if (tint) |t| for (0..3) |c| {
            dst[l + c] = @intCast((@as(u16, dst[l + c]) + t[c]) / 2);
        };
        const src: ?[3]u8 = switch (d.class) {
            .accepted => sourceColor(d.src, window),
            .rejected => rejected_source_color,
            .none => null,
        };
        if (src) |sc| dst[r..][0..3].* = sc;
    };
    // ROI の枠
    for (0..2) |panel| {
        const ox = panel * w;
        for (roi.x..roi.x + roi.w) |x| {
            dst[(roi.y * dw + ox + x) * 3 ..][0..3].* = border;
            dst[((roi.y + roi.h - 1) * dw + ox + x) * 3 ..][0..3].* = border;
        }
        for (roi.y..roi.y + roi.h) |y| {
            dst[(y * dw + ox + roi.x) * 3 ..][0..3].* = border;
            dst[(y * dw + ox + roi.x + roi.w - 1) * 3 ..][0..3].* = border;
        }
    }
}

test "debug_view: each pixel gets the color of how it was restored, and where it was borrowed from" {
    const w = 8;
    const h = 6;
    var input: [w * h * 3]u8 = undefined;
    @memset(&input, 100);
    var output: [w * h * 3]u8 = undefined;
    @memset(&output, 100);
    var prov: [w * h]Provenance = undefined;
    @memset(&prov, .original);
    const roi: temporal.Rect = .{ .x = 2, .y = 1, .w = 4, .h = 4 };
    var detail = [_]temporal.Detail{.{}} ** 16;
    // (3,2) 戻した（3 フレーム前から）、(4,2) 不採用 → 埋めた、(3,3) 候補なし → 埋めた、(4,3) 埋めていない
    prov[2 * w + 3] = .temporal_real;
    detail[1 * 4 + 1] = .{ .class = .accepted, .src = -3 };
    prov[2 * w + 4] = .spatial_inpainted;
    detail[1 * 4 + 2] = .{ .class = .rejected, .src = 2 };
    prov[3 * w + 3] = .spatial_inpainted;
    prov[3 * w + 4] = .unrecovered;
    var dst: [w * 2 * h * 3]u8 = undefined;
    render(&dst, w, h, &input, &output, &prov, roi, roi, &detail, 15);
    const at = struct {
        fn f(d: []const u8, x: usize, y: usize) [3]u8 {
            return d[(y * w * 2 + x) * 3 ..][0..3].*;
        }
    }.f;
    try std.testing.expectEqual([3]u8{ 50, 160, 50 }, at(&dst, 3, 2)); // (100 + 緑) / 2
    try std.testing.expectEqual([3]u8{ 177, 70, 70 }, at(&dst, 4, 2)); // 赤
    try std.testing.expectEqual([3]u8{ 80, 110, 177 }, at(&dst, 3, 3)); // 青
    try std.testing.expectEqual([3]u8{ 177, 50, 177 }, at(&dst, 4, 3)); // マゼンタ
    try std.testing.expectEqual([3]u8{ 100, 100, 100 }, at(&dst, 0, 0)); // 範囲の外はそのまま
    // 右: 借りたフレームの色（3 フレーム前 = 青系）、不採用 = 灰色、それ以外は入力を暗くしたもの
    try std.testing.expectEqual(sourceColor(-3, 15), at(&dst, w + 3, 2));
    try std.testing.expectEqual(rejected_source_color, at(&dst, w + 4, 2));
    try std.testing.expectEqual([3]u8{ 35, 35, 35 }, at(&dst, w + 0, 0));
    // ROI の枠は白
    try std.testing.expectEqual(border, at(&dst, 2, 1));
    try std.testing.expectEqual(border, at(&dst, w + 5, 4));
    // 過去は青系・未来は橙系で、遠いほど明るい
    try std.testing.expect(sourceColor(-1, 15)[2] == 255 and sourceColor(1, 15)[0] == 255);
    try std.testing.expect(sourceColor(-15, 15)[1] > sourceColor(-1, 15)[1]);
}
