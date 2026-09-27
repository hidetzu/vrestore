//! 推測で埋めた画素（spatial_inpainted）を、時間方向に落ち着かせる。
//!
//! harmonic は埋める範囲のすぐ外の画素を手がかりにする。その画素には圧縮の乱れがフレームごとに違って乗るので、
//! 平らな背景では埋めた面が細かくちらつく（手持ちの実写のフェードで、背景 0.01〜0.27 に対して埋めた面 0.57〜1.35）。
//! そこで、前のフレームでも埋めた画素は
//!
//!   G_t = λ F_t + (1 − λ)(G_{t−1} + Δ)
//!
//! にする（F_t は今のフレームで埋めた値、G は落ち着かせた値、Δ は範囲の中で見えている画素の明るさの平均の変化）。
//! 明るさの変化（フェード）は Δ で遅れずに追い、細かい変化だけを平均する。
//!
//! 見えている画素の変化が Δ だけで説明できない（背景が動く・場面が変わる）ときは混ぜない。前のフレームの埋めは
//! 別の場所の推測になっているので、混ぜるとずれる。
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

const ring = 4;

pub const Params = struct {
    /// 今のフレームの埋めの重み（1 なら落ち着かせない）
    lambda: f32 = 0.3,
    /// 見えている画素の変化から Δ を引いた残りの絶対値の平均が、これを超えたら混ぜない（8 bit の値）
    max_change: f32 = 2,
};

pub const State = struct {
    area: Rect,
    /// 前のフレームの落ち着かせた値（範囲の画素ごと、RGB）と、その画素を埋めたか
    g: []f32,
    filled: []bool,
    /// 前のフレームの入力（範囲の画素ごと、RGB）
    prev_in: []u8,
    have_prev: bool = false,
    /// 混ぜたフレーム数と、混ぜなかった（動いた・切り替わった）フレーム数
    blended: u64 = 0,
    reset: u64 = 0,

    /// `fill_area`（埋める画素がある範囲）を周り `ring` px だけ広げた範囲（画面の中）を見る。
    /// 範囲の中の画素をすべて埋めていても、周りの見えている画素で明るさの変化を測れる
    pub fn init(gpa: std.mem.Allocator, fill_area: Rect, frame_w: u32, frame_h: u32) !State {
        const x0 = fill_area.x -| ring;
        const y0 = fill_area.y -| ring;
        const area: Rect = .{ .x = x0, .y = y0, .w = @min(frame_w, fill_area.x + fill_area.w + ring) - x0, .h = @min(frame_h, fill_area.y + fill_area.h + ring) - y0 };
        const n = @as(usize, area.w) * area.h;
        return .{ .area = area, .g = try gpa.alloc(f32, n * 3), .filled = try gpa.alloc(bool, n), .prev_in = try gpa.alloc(u8, n * 3) };
    }

    pub fn deinit(s: State, gpa: std.mem.Allocator) void {
        gpa.free(s.g);
        gpa.free(s.filled);
        gpa.free(s.prev_in);
    }

    /// `out`（RGB24、幅 w、埋めた後）の範囲の中で、spatial_inpainted の画素を落ち着かせて書き直す。
    /// `input` は同じフレームの入力（埋める前）、`prov` は各画素の由来
    pub fn apply(s: *State, out: []u8, input: []const u8, w: u32, prov: []const Provenance, p: Params) void {
        const a = s.area;
        // 見えている（spatial_inpainted でない）画素の、前のフレームからの変化: 平均 Δ と、Δ を引いた残り
        var blend = s.have_prev;
        var delta = [3]f32{ 0, 0, 0 };
        if (blend) {
            var sum = [3]f64{ 0, 0, 0 };
            var n: usize = 0;
            for (0..a.h) |yy| for (0..a.w) |xx| {
                const i = (a.y + yy) * w + a.x + xx;
                const k = yy * a.w + xx;
                if (prov[i] == .spatial_inpainted or s.filled[k]) continue;
                for (0..3) |c| sum[c] += @as(f64, @floatFromInt(input[i * 3 + c])) - @as(f64, @floatFromInt(s.prev_in[k * 3 + c]));
                n += 1;
            };
            if (n == 0) blend = false else {
                for (&delta, sum) |*d, v| d.* = @floatCast(v / @as(f64, @floatFromInt(n)));
                var dev: f64 = 0;
                for (0..a.h) |yy| for (0..a.w) |xx| {
                    const i = (a.y + yy) * w + a.x + xx;
                    const k = yy * a.w + xx;
                    if (prov[i] == .spatial_inpainted or s.filled[k]) continue;
                    for (0..3) |c| dev += @abs(@as(f64, @floatFromInt(input[i * 3 + c])) - @as(f64, @floatFromInt(s.prev_in[k * 3 + c])) - delta[c]);
                };
                if (dev / @as(f64, @floatFromInt(n * 3)) > p.max_change) blend = false;
            }
        }
        if (s.have_prev) {
            if (blend) s.blended += 1 else s.reset += 1;
        }
        for (0..a.h) |yy| for (0..a.w) |xx| {
            const i = (a.y + yy) * w + a.x + xx;
            const k = yy * a.w + xx;
            const now = prov[i] == .spatial_inpainted;
            for (0..3) |c| {
                const f: f32 = @floatFromInt(out[i * 3 + c]);
                if (now) {
                    const v = if (blend and s.filled[k]) p.lambda * f + (1 - p.lambda) * (s.g[k * 3 + c] + delta[c]) else f;
                    s.g[k * 3 + c] = v;
                    out[i * 3 + c] = @intFromFloat(std.math.clamp(@round(v), 0, 255));
                }
                s.prev_in[k * 3 + c] = input[i * 3 + c];
            }
            s.filled[k] = now;
        };
        s.have_prev = true;
    }
};

// ---- tests -------------------------------------------------------------------

test "stabilize: a static background averages the jitter of the fill, and a fade is followed without lag" {
    const gpa = std.testing.allocator;
    const w = 12;
    const h = 8;
    var st = try State.init(gpa, .{ .x = 4, .y = 3, .w = 4, .h = 2 }, w, h);
    defer st.deinit(gpa);
    var prov: [w * h]Provenance = undefined;
    @memset(&prov, .original);
    for (3..5) |y| for (4..8) |x| {
        prov[y * w + x] = .spatial_inpainted;
    };
    var prng: std.Random.DefaultPrng = .init(1);
    var jitter_in: f64 = 0;
    var jitter_out: f64 = 0;
    var last_out: u8 = 0;
    for (0..60) |t| {
        // 背景は 100 から 1 フレームに +1 ずつ明るくなる（フェード）。埋めた値は正しい明るさ ± 6 の乱れ
        const level: u8 = @intCast(100 + t);
        var input: [w * h * 3]u8 = undefined;
        @memset(&input, level);
        var out = input;
        const noise: i32 = prng.random().intRangeAtMost(i32, -6, 6);
        for (3..5) |y| for (4..8) |x| {
            @memset(out[(y * w + x) * 3 ..][0..3], @intCast(@as(i32, level) + noise));
        };
        st.apply(&out, &input, w, &prov, .{});
        const o = out[(3 * w + 5) * 3];
        if (t >= 10) {
            jitter_in += @abs(@as(f64, @floatFromInt(noise)));
            jitter_out += @abs(@as(f64, @floatFromInt(o)) - @as(f64, @floatFromInt(level)));
        }
        last_out = o;
    }
    // 乱れは半分未満に減り、明るさはフェードに遅れない（最後のフレームの正しい値 159 から ±3 以内）
    try std.testing.expect(jitter_out < 0.5 * jitter_in);
    try std.testing.expect(@abs(@as(i32, last_out) - 159) <= 3);
    try std.testing.expectEqual(@as(u64, 59), st.blended);
}

test "stabilize: the brightness change is measured around the area when every pixel in it is guessed" {
    // 範囲 (4,3) 4x2 をすべて埋めている。見えている画素は周りだけ
    const gpa = std.testing.allocator;
    const w = 12;
    const h = 8;
    var st = try State.init(gpa, .{ .x = 4, .y = 3, .w = 4, .h = 2 }, w, h);
    defer st.deinit(gpa);
    var prov: [w * h]Provenance = undefined;
    @memset(&prov, .original);
    for (3..5) |y| for (4..8) |x| {
        prov[y * w + x] = .spatial_inpainted;
    };
    for (0..5) |t| {
        const level: u8 = @intCast(100 + 10 * t);
        var input: [w * h * 3]u8 = undefined;
        @memset(&input, level);
        var out = input;
        st.apply(&out, &input, w, &prov, .{});
        // 埋めた値（= 正しい明るさ）はフェードに遅れない
        try std.testing.expectEqual(level, out[(3 * w + 5) * 3]);
    }
    try std.testing.expectEqual(@as(u64, 4), st.blended);
}

test "stabilize: when the visible background changes (it moved), the fill is not blended" {
    const gpa = std.testing.allocator;
    const w = 12;
    const h = 8;
    var st = try State.init(gpa, .{ .x = 4, .y = 3, .w = 4, .h = 2 }, w, h);
    defer st.deinit(gpa);
    var prov: [w * h]Provenance = undefined;
    @memset(&prov, .original);
    prov[3 * w + 5] = .spatial_inpainted;
    var prng: std.Random.DefaultPrng = .init(2);
    for (0..10) |_| {
        // 見えている画素が毎フレームばらばらに変わる（背景が動いている）
        var input: [w * h * 3]u8 = undefined;
        prng.random().bytes(&input);
        var out = input;
        @memset(out[(3 * w + 5) * 3 ..][0..3], 77);
        st.apply(&out, &input, w, &prov, .{});
        // 混ぜないので、今のフレームで埋めた値のまま
        try std.testing.expectEqual(@as(u8, 77), out[(3 * w + 5) * 3]);
    }
    try std.testing.expectEqual(@as(u64, 0), st.blended);
    try std.testing.expectEqual(@as(u64, 9), st.reset);
}
