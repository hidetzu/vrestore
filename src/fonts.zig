//! 操作パネルの文字に使うフォントファイルを探す（docs/adr/0009）。
//!
//! SF（macOS のシステムフォント）などはライセンス上リポジトリに同梱できないので、実行する環境にあるものを読む。
//! 見つからなければ null（gui.zig は内蔵のビットマップフォント glyphs.zig に切り替える）。

const std = @import("std");
const builtin = @import("builtin");

/// 探す順。先にあるほど優先
pub const candidates: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    },
    else => &.{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/opentype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    },
};

/// 使うフォントを決める。`explicit`（--font か VRESTORE_FONT）があればそれだけを見る（無ければ null。
/// 指定したものが無いのに黙って別のフォントにすると、指定が効いていないことに気付けない）。
/// なければ候補を順に、`exists` が true を返した最初のもの
pub fn pick(explicit: ?[]const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) ?[]const u8 {
    if (explicit) |p| return if (exists(ctx, p)) p else null;
    for (candidates) |c| if (exists(ctx, c)) return c;
    return null;
}

test "fonts: an explicit font wins, and is not silently replaced when missing" {
    const Set = struct { present: []const []const u8 };
    const f = struct {
        fn f(s: Set, p: []const u8) bool {
            for (s.present) |q| if (std.mem.eql(u8, p, q)) return true;
            return false;
        }
    }.f;
    const all: Set = .{ .present = candidates };
    try std.testing.expectEqualStrings(candidates[0], pick(null, all, f).?);
    // 1 番目が無ければ 2 番目
    const second: Set = .{ .present = candidates[1..] };
    try std.testing.expectEqualStrings(candidates[1], pick(null, second, f).?);
    // 何も無ければ null（ビットマップフォントへ）
    try std.testing.expectEqual(@as(?[]const u8, null), pick(null, Set{ .present = &.{} }, f));
    // 明示したものがあればそれ。無ければ候補に落とさず null
    try std.testing.expectEqualStrings("/my/font.ttf", pick("/my/font.ttf", Set{ .present = &.{"/my/font.ttf"} }, f).?);
    try std.testing.expectEqual(@as(?[]const u8, null), pick("/missing.ttf", all, f));
}
