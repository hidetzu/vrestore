//! Spatial Inpainting: どの方式でも戻せなかった画素を、周囲の見えている画素から推測して埋める。
//!
//! ⚠ ここで作る画素は映像内の証拠ではなく推測。由来は spatial_inpainted で、coverage（戻せた割合）には数えない
//! （docs/adr/0006、0008）。埋めるのは provenance が unrecovered の画素だけで、Temporal で戻した実画素
//! （temporal_real）と ROI の外（original）を手がかりにする。
//!
//! 方式:
//! - directional: 上下左右へ進んで最初に当たる見えている画素を、距離の逆数で重み付けして混ぜる
//!   （FFmpeg の delogo、mp4tool の inpaintBorder と同じ考え方）
//! - harmonic: directional を初期値に、見えている画素を境界条件にしてラプラス方程式を反復で解く。
//!   埋めた部分が周りと滑らかにつながり、directional の縦横の筋が消える
//!
//! この module は FFmpeg に依存しない。

const std = @import("std");
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Method = enum { none, directional, harmonic };

/// harmonic の反復回数。⚠ 較正は docs/SPEC.md §4
pub const harmonic_iterations = 300;

/// `rgb`（RGB24、幅 w）の ROI の中で、`prov` が unrecovered の画素を埋め、由来を spatial_inpainted にする。
/// 埋めた画素の数を返す。手がかりが無い画素（上下左右どちらにも見えている画素が無い）は unrecovered のまま残す
pub fn fill(gpa: std.mem.Allocator, method: Method, rgb: []u8, w: u32, h: u32, prov: []Provenance, roi: Rect) !usize {
    if (method == .none) return 0;
    // 埋める画素の一覧（ROI の中だけを見る）
    var holes: std.ArrayList(u32) = .empty;
    defer holes.deinit(gpa);
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        const i = y * w + x;
        if (prov[i] == .unrecovered) try holes.append(gpa, @intCast(i));
    };
    if (holes.items.len == 0) return 0;

    const filled = try gpa.alloc(bool, holes.items.len);
    defer gpa.free(filled);
    for (holes.items, filled) |i, *ok| ok.* = directional(rgb, w, h, prov, i);
    var n: usize = 0;
    for (holes.items, filled) |i, ok| if (ok) {
        n += 1;
        prov[i] = .spatial_inpainted;
    };
    if (method == .harmonic) try relax(gpa, rgb, w, h, prov, roi);
    return n;
}

fn known(p: Provenance) bool {
    return switch (p) {
        .original, .temporal_real => true,
        .unrecovered, .spatial_inpainted => false,
    };
}

/// 上下左右へ進み、最初に当たる見えている画素を距離の逆数で混ぜて `i` に書く。どちらにも無ければ false
fn directional(rgb: []u8, w: u32, h: u32, prov: []const Provenance, i: u32) bool {
    const x0: i64 = i % w;
    const y0: i64 = i / w;
    var acc = [3]f64{ 0, 0, 0 };
    var wsum: f64 = 0;
    for ([_][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
        var x = x0;
        var y = y0;
        var dist: f64 = 0;
        while (true) {
            x += d[0];
            y += d[1];
            dist += 1;
            if (x < 0 or y < 0 or x >= w or y >= h) break;
            const j: usize = @intCast(y * w + x);
            if (!known(prov[j])) continue;
            const wt = 1 / dist;
            for (0..3) |c| acc[c] += wt * @as(f64, @floatFromInt(rgb[j * 3 + c]));
            wsum += wt;
            break;
        }
    }
    if (wsum == 0) return false;
    for (0..3) |c| rgb[i * 3 + c] = @intFromFloat(std.math.clamp(@round(acc[c] / wsum), 0, 255));
    return true;
}

/// 埋めた画素を、上下左右の平均で置き換えることを繰り返す（ラプラス方程式の Gauss-Seidel 反復）。
/// 見えている画素（known）は動かさない。画面の端は、画面の中の隣だけで平均する
fn relax(gpa: std.mem.Allocator, rgb: []u8, w: u32, h: u32, prov: []const Provenance, roi: Rect) !void {
    // 反復は小数で持つ（毎回 u8 に丸めると滑らかにならない）
    const rw = roi.w;
    const rh = roi.h;
    const buf = try gpa.alloc(f32, @as(usize, rw) * rh * 3);
    defer gpa.free(buf);
    for (0..rh) |yy| for (0..rw) |xx| {
        const i = (roi.y + yy) * w + roi.x + xx;
        for (0..3) |c| buf[(yy * rw + xx) * 3 + c] = @floatFromInt(rgb[i * 3 + c]);
    };
    const at = struct {
        fn f(rgbv: []const u8, b: []const f32, ww: u32, r: Rect, x: i64, y: i64, c: usize) f32 {
            if (x >= r.x and x < @as(i64, r.x) + r.w and y >= r.y and y < @as(i64, r.y) + r.h)
                return b[((@as(usize, @intCast(y)) - r.y) * r.w + @as(usize, @intCast(x)) - r.x) * 3 + c];
            return @floatFromInt(rgbv[(@as(usize, @intCast(y)) * ww + @as(usize, @intCast(x))) * 3 + c]);
        }
    }.f;
    for (0..harmonic_iterations) |_| {
        for (0..rh) |yy| for (0..rw) |xx| {
            const x: i64 = @intCast(roi.x + xx);
            const y: i64 = @intCast(roi.y + yy);
            if (prov[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))] != .spatial_inpainted) continue;
            for (0..3) |c| {
                var s: f32 = 0;
                var n: f32 = 0;
                for ([_][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
                    const nx = x + d[0];
                    const ny = y + d[1];
                    if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                    s += at(rgb, buf, w, roi, nx, ny, c);
                    n += 1;
                }
                buf[(yy * rw + xx) * 3 + c] = s / n;
            }
        };
    }
    for (0..rh) |yy| for (0..rw) |xx| {
        const i = (roi.y + yy) * w + roi.x + xx;
        if (prov[i] != .spatial_inpainted) continue;
        for (0..3) |c| rgb[i * 3 + c] = @intFromFloat(std.math.clamp(@round(buf[(yy * rw + xx) * 3 + c]), 0, 255));
    };
}

// ---- tests -------------------------------------------------------------------

fn gradientImage(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const rgb = try gpa.alloc(u8, @as(usize, w) * h * 3);
    for (0..h) |y| for (0..w) |x| {
        rgb[(y * w + x) * 3 ..][0..3].* = .{ @intCast(x * 4), @intCast(y * 4), 100 };
    };
    return rgb;
}

test "spatial: fills only unrecovered pixels and labels them spatial_inpainted" {
    const gpa = std.testing.allocator;
    const w = 32;
    const h = 24;
    const rgb = try gradientImage(gpa, w, h);
    defer gpa.free(rgb);
    const prov = try gpa.alloc(Provenance, w * h);
    defer gpa.free(prov);
    @memset(prov, .original);
    const roi: Rect = .{ .x = 8, .y = 6, .w = 12, .h = 8 };
    // ROI の中: 左半分は Temporal で戻した実画素、右半分は戻せなかった（焼かれたまま = 白）
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        if (x < roi.x + 6) {
            prov[y * w + x] = .temporal_real;
        } else {
            prov[y * w + x] = .unrecovered;
            rgb[(y * w + x) * 3 ..][0..3].* = .{ 255, 255, 255 };
        }
    };
    const kept = try gpa.dupe(u8, rgb);
    defer gpa.free(kept);
    const n = try fill(gpa, .directional, rgb, w, h, prov, roi);
    try std.testing.expectEqual(@as(usize, 6 * 8), n);
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        const inside = x >= roi.x and x < roi.x + roi.w and y >= roi.y and y < roi.y + roi.h;
        if (inside and x >= roi.x + 6) {
            try std.testing.expectEqual(Provenance.spatial_inpainted, prov[i]);
        } else {
            // 見えている画素（ROI の外・Temporal の実画素）は変えない
            try std.testing.expectEqualSlices(u8, kept[i * 3 ..][0..3], rgb[i * 3 ..][0..3]);
        }
    };
}

test "spatial: harmonic reproduces a linear gradient exactly, directional is close" {
    // 線形の勾配はラプラス方程式の解なので、harmonic は正解（元の勾配）に収束する
    const gpa = std.testing.allocator;
    const w = 40;
    const h = 30;
    const roi: Rect = .{ .x = 10, .y = 8, .w = 14, .h = 10 };
    for ([_]Method{ .directional, .harmonic }) |m| {
        const truth = try gradientImage(gpa, w, h);
        defer gpa.free(truth);
        const rgb = try gpa.dupe(u8, truth);
        defer gpa.free(rgb);
        const prov = try gpa.alloc(Provenance, w * h);
        defer gpa.free(prov);
        @memset(prov, .original);
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
            prov[y * w + x] = .unrecovered;
            rgb[(y * w + x) * 3 ..][0..3].* = .{ 0, 0, 0 };
        };
        _ = try fill(gpa, m, rgb, w, h, prov, roi);
        var worst: i32 = 0;
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| for (0..3) |c| {
            const i = (y * w + x) * 3 + c;
            worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, truth[i]) - rgb[i]))));
        };
        switch (m) {
            .harmonic => try std.testing.expect(worst <= 1),
            .directional => try std.testing.expect(worst <= 12),
            .none => unreachable,
        }
    }
}

test "spatial: harmonic makes every filled pixel the average of its neighbours, directional does not" {
    // 境界が乱数の模様のとき、線形補間では解けない。harmonic はラプラス方程式を解くので、埋めた各画素は
    // 上下左右の平均に（u8 に丸めた分を除いて）一致する。directional は一致しない
    const gpa = std.testing.allocator;
    const w = 24;
    const h = 20;
    const roi: Rect = .{ .x = 6, .y = 5, .w = 10, .h = 8 };
    var prng: std.Random.DefaultPrng = .init(21);
    const base = try gpa.alloc(u8, w * h * 3);
    defer gpa.free(base);
    prng.random().bytes(base);
    var worst: [2]f32 = undefined;
    for ([_]Method{ .directional, .harmonic }, &worst) |m, *wst| {
        const rgb = try gpa.dupe(u8, base);
        defer gpa.free(rgb);
        const prov = try gpa.alloc(Provenance, w * h);
        defer gpa.free(prov);
        @memset(prov, .original);
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
            prov[y * w + x] = .unrecovered;
        };
        _ = try fill(gpa, m, rgb, w, h, prov, roi);
        wst.* = 0;
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| for (0..3) |c| {
            var sum: f32 = 0;
            for ([_][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
                const nx: usize = @intCast(@as(i64, @intCast(x)) + d[0]);
                const ny: usize = @intCast(@as(i64, @intCast(y)) + d[1]);
                sum += @floatFromInt(rgb[(ny * w + nx) * 3 + c]);
            }
            wst.* = @max(wst.*, @abs(@as(f32, @floatFromInt(rgb[(y * w + x) * 3 + c])) - sum / 4));
        };
    }
    try std.testing.expect(worst[1] <= 1.5); // harmonic: 丸めの分だけ
    try std.testing.expect(worst[0] > 5); // directional: 平均から離れた画素がある
}

test "spatial: none leaves everything unrecovered" {
    const gpa = std.testing.allocator;
    const rgb = try gradientImage(gpa, 8, 8);
    defer gpa.free(rgb);
    var prov = [_]Provenance{.unrecovered} ** 64;
    try std.testing.expectEqual(@as(usize, 0), try fill(gpa, .none, rgb, 8, 8, &prov, .{ .x = 0, .y = 0, .w = 8, .h = 8 }));
    try std.testing.expectEqual(Provenance.unrecovered, prov[0]);
}
