//! 操作パネルの文字（時刻・フレーム番号）を描くための 5 x 7 のビットマップフォント。
//! SDL2 には文字を描く機能が無く、フォントのライブラリを足すほどではないので、使う文字だけを持つ（docs/adr/0009）。
//! 数字と ": . / # -" と空白だけ。

const std = @import("std");

pub const width = 5;
pub const height = 7;
/// 文字と文字の間（ドット）
pub const spacing = 1;

/// 各行の下位 5 ビットが左から右（ビット 4 が左端）
pub fn glyph(c: u8) ?[height]u8 {
    return switch (c) {
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        ':' => .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 },
        '.' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        '#' => .{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => null,
    };
}

/// `text` を `scale` 倍で描いたときの幅（px）。知らない文字は空白と同じ幅
pub fn textWidth(text: []const u8, scale: u32) u32 {
    if (text.len == 0) return 0;
    return @intCast((text.len * (width + spacing) - spacing) * scale);
}

/// 点を 1 つずつ `plot(ctx, x, y)` に渡す（左上が (0, 0)、`scale` 倍の四角の左上）。知らない文字は描かない
pub fn render(text: []const u8, scale: u32, ctx: anytype, comptime plot: fn (@TypeOf(ctx), u32, u32) void) void {
    for (text, 0..) |ch, i| {
        const g = glyph(ch) orelse continue;
        const ox: u32 = @intCast(i * (width + spacing) * scale);
        for (g, 0..) |row, y| for (0..width) |x| {
            if ((row >> @intCast(width - 1 - x)) & 1 == 1) plot(ctx, ox + @as(u32, @intCast(x)) * scale, @as(u32, @intCast(y)) * scale);
        };
    }
}

test "glyphs: every character the panel uses has a glyph" {
    for ("0123456789:./#- ") |c| try std.testing.expect(glyph(c) != null);
    try std.testing.expectEqual(@as(?[height]u8, null), glyph('x'));
}

test "glyphs: width and the dots of a character" {
    try std.testing.expectEqual(@as(u32, (3 * 6 - 1) * 2), textWidth("1:2", 2));
    // "1" の中央の縦棒（x = 2）は 7 行すべてに点がある
    var dots: [height]bool = .{false} ** height;
    const Ctx = struct { d: *[height]bool };
    render("1", 1, Ctx{ .d = &dots }, struct {
        fn f(c: Ctx, x: u32, y: u32) void {
            if (x == 2) c.d[y] = true;
        }
    }.f);
    for (dots) |d| try std.testing.expect(d);
}
