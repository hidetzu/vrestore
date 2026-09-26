//! 復元結果の各画素が、どの方式で作られたか（provenance）。
//!
//! 「元に戻した画素」と「推測した画素」を区別できることがこのプロジェクトの前提（CLAUDE.md §1、docs/adr/0006）。
//! 復元方式を足すときは、ここに値を足す。下の switch はすべて網羅なので、足すとコンパイラが
//! 「coverage に数えるか」「GUI で何色か」「名前」を決めるよう求める。
//!
//! ファイル形式（`vrestore restore --provenance`）: 1 画素 1 バイト、フレームごとに幅 x 高さ、行優先。
//! ⚠ 値は形式の一部なので変えない。足すときは空いている値を使う

const std = @import("std");

pub const Provenance = enum(u8) {
    /// ROI の外。入力の画素そのまま（処理の対象外）
    original = 0,
    /// ROI の中で、どの方式でも戻せなかった。入力の画素（焼かれたまま）を残している
    unrecovered = 1,
    /// Temporal Recovery: 背景が動いて見えている別フレームの実画素（docs/adr/0005）
    temporal_real = 2,
    // 予約: alpha_recovered = 3（半透明のウォーターマークを外して戻した画素）
    /// Spatial Inpainting: 周囲の見えている画素から推測して埋めた（spatial.zig）。映像内の証拠ではない
    spatial_inpainted = 4,

    /// 映像内の証拠から戻した画素か。coverage はこれを数える。
    /// ⚠ 推測で埋めた画素（spatial_inpainted を足したとき）は false にする。coverage は「戻せた割合」であって
    /// 「埋めた割合」ではない
    pub fn isRecovered(p: Provenance) bool {
        return switch (p) {
            .original, .unrecovered => false,
            .temporal_real => true,
            // 推測で埋めた画素は「戻せた」に数えない（docs/adr/0006）
            .spatial_inpainted => false,
        };
    }

    /// ROI の中の画素か（集計の分母）
    pub fn inRoi(p: Provenance) bool {
        return switch (p) {
            .original => false,
            .unrecovered, .temporal_real, .spatial_inpainted => true,
        };
    }

    /// GUI で由来を色分けするときの色。null はそのまま（色を付けない）
    pub fn color(p: Provenance) ?[3]u8 {
        return switch (p) {
            .original => null,
            .unrecovered => .{ 255, 0, 255 },
            .temporal_real => .{ 0, 200, 90 },
            .spatial_inpainted => .{ 255, 150, 0 },
        };
    }
};

/// ファイルから読んだ 1 バイトを解釈する。知らない値は null（別の版が書いた・壊れている）
pub fn fromByte(b: u8) ?Provenance {
    return std.enums.fromInt(Provenance, b);
}

pub const count = std.meta.fields(Provenance).len;

/// 由来ごとの画素数
pub const Tally = struct {
    counts: std.EnumArray(Provenance, usize) = .initFill(0),

    pub fn add(t: *Tally, p: Provenance) void {
        t.counts.getPtr(p).* += 1;
    }

    pub fn merge(t: *Tally, other: Tally) void {
        for (std.enums.values(Provenance)) |p| t.counts.getPtr(p).* += other.counts.get(p);
    }

    /// ROI の中の画素数
    pub fn roiPixels(t: Tally) usize {
        var n: usize = 0;
        for (std.enums.values(Provenance)) |p| if (p.inRoi()) {
            n += t.counts.get(p);
        };
        return n;
    }

    /// 戻せた画素数（isRecovered の合計）
    pub fn recovered(t: Tally) usize {
        var n: usize = 0;
        for (std.enums.values(Provenance)) |p| if (p.isRecovered()) {
            n += t.counts.get(p);
        };
        return n;
    }

    /// 戻せた割合。ROI の画素が無ければ 0
    pub fn coverage(t: Tally) f64 {
        const n = t.roiPixels();
        return if (n == 0) 0 else @as(f64, @floatFromInt(t.recovered())) / @as(f64, @floatFromInt(n));
    }

    /// ROI の中で由来 `p` の割合
    pub fn fraction(t: Tally, p: Provenance) f64 {
        const n = t.roiPixels();
        return if (n == 0) 0 else @as(f64, @floatFromInt(t.counts.get(p))) / @as(f64, @floatFromInt(n));
    }

    /// `{"unrecovered":N,"temporal_real":M}` の形で、ROI の中の由来ごとの画素数を書く
    pub fn writeJson(t: Tally, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("{");
        var first = true;
        for (std.enums.values(Provenance)) |p| {
            if (!p.inRoi()) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\":{d}", .{ @tagName(p), t.counts.get(p) });
        }
        try w.writeAll("}");
    }
};

test "provenance: byte values are part of the file format" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Provenance.original));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Provenance.unrecovered));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Provenance.temporal_real));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Provenance.spatial_inpainted));
    try std.testing.expectEqual(Provenance.temporal_real, fromByte(2).?);
    try std.testing.expectEqual(Provenance.spatial_inpainted, fromByte(4).?);
    // 予約した値（3）と知らない値は読めない
    try std.testing.expectEqual(@as(?Provenance, null), fromByte(3));
    try std.testing.expectEqual(@as(?Provenance, null), fromByte(255));
}

test "provenance: coverage counts recovered pixels over the ROI, not pixels outside it" {
    var t: Tally = .{};
    for (0..10) |_| t.add(.original);
    for (0..3) |_| t.add(.unrecovered);
    for (0..7) |_| t.add(.temporal_real);
    try std.testing.expectEqual(@as(usize, 10), t.roiPixels());
    try std.testing.expectEqual(@as(usize, 7), t.recovered());
    try std.testing.expectEqual(@as(f64, 0.7), t.coverage());
    try std.testing.expectEqual(@as(f64, 0.3), t.fraction(.unrecovered));

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.writeJson(&w);
    try std.testing.expectEqualStrings("{\"unrecovered\":3,\"temporal_real\":7,\"spatial_inpainted\":0}", w.buffered());

    // 推測で埋めた画素は ROI の画素には数えるが、coverage（戻せた割合）には数えない
    for (0..3) |_| t.add(.spatial_inpainted);
    try std.testing.expectEqual(@as(usize, 13), t.roiPixels());
    try std.testing.expectEqual(@as(usize, 7), t.recovered());
}
