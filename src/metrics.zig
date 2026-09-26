//! 復元の良さを「元の動画にどれだけ近いか」で測る指標。矩形（ウォーターマークの場所）の中だけを見る。
//!
//! 定義は FFmpeg の `ssim` / `psnr` フィルタに揃えてある。自前の指標を自前の実装とだけ比べても
//! 何も示さないので、CI で FFmpeg とフレームごとに突き合わせる（build.zig の `metrics crosscheck`）。
//!
//! - MSE / PSNR: R, G, B それぞれの二乗誤差の平均。PSNR は 10 log10(255² / MSE)
//! - SSIM: x264 由来の方式（FFmpeg の vf_ssim と同じ）。4x4 のブロック和から 8x8 の窓を 4px 刻みで作り、
//!   窓ごとの SSIM を平均する。R, G, B それぞれ出し、全体はその平均

const std = @import("std");

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// RGB24 で詰めた画像
pub const Image = struct {
    width: u32,
    height: u32,
    rgb: []const u8,
};

pub const FrameScore = struct {
    /// R, G, B の二乗誤差の平均
    mse: [3]f64,
    /// R, G, B の SSIM
    ssim: [3]f64,

    pub fn mseAvg(s: FrameScore) f64 {
        return (s.mse[0] + s.mse[1] + s.mse[2]) / 3;
    }

    pub fn ssimAll(s: FrameScore) f64 {
        return (s.ssim[0] + s.ssim[1] + s.ssim[2]) / 3;
    }
};

pub const Error = error{
    /// 2 枚の大きさが違う
    SizeMismatch,
    /// 矩形が画像からはみ出している
    RectOutside,
    /// SSIM の窓（8x8）が 1 つも取れない
    RectTooSmall,
};

/// `rect` の中で `reference` と `test_img` を比べる。
pub fn score(reference: Image, test_img: Image, rect: Rect) Error!FrameScore {
    if (reference.width != test_img.width or reference.height != test_img.height) return error.SizeMismatch;
    if (@as(u64, rect.x) + rect.w > reference.width or @as(u64, rect.y) + rect.h > reference.height) return error.RectOutside;
    if (rect.w < 8 or rect.h < 8) return error.RectTooSmall;
    var s: FrameScore = undefined;
    for (0..3) |c| {
        s.mse[c] = mse(reference, test_img, rect, c);
        s.ssim[c] = ssimPlane(reference, test_img, rect, c);
    }
    return s;
}

/// MSE から PSNR (dB)。MSE が 0（完全一致）なら null
pub fn psnr(mse_value: f64) ?f64 {
    if (mse_value <= 0) return null;
    return 10 * std.math.log10(255.0 * 255.0 / mse_value);
}

inline fn px(img: Image, x: usize, y: usize, c: usize) i64 {
    return img.rgb[(y * img.width + x) * 3 + c];
}

fn mse(a: Image, b: Image, r: Rect, c: usize) f64 {
    var sum: u64 = 0;
    for (r.y..r.y + r.h) |y| {
        for (r.x..r.x + r.w) |x| {
            const d = px(a, x, y, c) - px(b, x, y, c);
            sum += @intCast(d * d);
        }
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(@as(u64, r.w) * r.h));
}

const BlockSums = struct { s1: i64, s2: i64, ss: i64, s12: i64 };

fn ssimPlane(a: Image, b: Image, r: Rect, c: usize) f64 {
    // 4x4 のブロック単位の和。端数の行・列は使わない（FFmpeg と同じ）
    const bw = r.w / 4;
    const bh = r.h / 4;
    var total: f64 = 0;
    var by: usize = 0;
    while (by + 1 < bh) : (by += 1) {
        var bx: usize = 0;
        while (bx + 1 < bw) : (bx += 1) {
            var w: BlockSums = .{ .s1 = 0, .s2 = 0, .ss = 0, .s12 = 0 };
            for (0..8) |dy| {
                for (0..8) |dx| {
                    const x = r.x + bx * 4 + dx;
                    const y = r.y + by * 4 + dy;
                    const va = px(a, x, y, c);
                    const vb = px(b, x, y, c);
                    w.s1 += va;
                    w.s2 += vb;
                    w.ss += va * va + vb * vb;
                    w.s12 += va * vb;
                }
            }
            total += ssimEnd(w);
        }
    }
    const n = (bw - 1) * (bh - 1);
    return total / @as(f64, @floatFromInt(n));
}

/// 8x8 窓 1 つの SSIM。定数と整数・単精度の使い分けは x264 / FFmpeg の ssim_end1 に合わせてある
fn ssimEnd(w: BlockSums) f64 {
    const c1: i64 = @intFromFloat(@round(0.01 * 0.01 * 255 * 255 * 64));
    const c2: i64 = @intFromFloat(@round(0.03 * 0.03 * 255 * 255 * 64 * 63));
    const vars = w.ss * 64 - w.s1 * w.s1 - w.s2 * w.s2;
    const covar = w.s12 * 64 - w.s1 * w.s2;
    const num = @as(f32, @floatFromInt(2 * w.s1 * w.s2 + c1)) * @as(f32, @floatFromInt(2 * covar + c2));
    const den = @as(f32, @floatFromInt(w.s1 * w.s1 + w.s2 * w.s2 + c1)) * @as(f32, @floatFromInt(vars + c2));
    return num / den;
}

// ---- tests -------------------------------------------------------------------

fn testImage(gpa: std.mem.Allocator, w: u32, h: u32, seed: u64) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const buf = try gpa.alloc(u8, @as(usize, w) * h * 3);
    prng.random().bytes(buf);
    return buf;
}

test "metrics: identical images score SSIM 1 and MSE 0" {
    const gpa = std.testing.allocator;
    const a = try testImage(gpa, 32, 24, 1);
    defer gpa.free(a);
    const img: Image = .{ .width = 32, .height = 24, .rgb = a };
    const s = try score(img, img, .{ .x = 3, .y = 2, .w = 20, .h = 16 });
    for (0..3) |c| {
        try std.testing.expectEqual(@as(f64, 0), s.mse[c]);
        try std.testing.expectApproxEqAbs(@as(f64, 1), s.ssim[c], 1e-6);
    }
    try std.testing.expectEqual(@as(?f64, null), psnr(s.mseAvg()));
}

test "metrics: MSE and PSNR of a uniform offset" {
    // 全画素を 10 ずらすと MSE は 100、PSNR は 10 log10(65025 / 100)
    const gpa = std.testing.allocator;
    var a = [_]u8{100} ** (16 * 16 * 3);
    var b = [_]u8{110} ** (16 * 16 * 3);
    const s = try score(.{ .width = 16, .height = 16, .rgb = &a }, .{ .width = 16, .height = 16, .rgb = &b }, .{ .x = 0, .y = 0, .w = 16, .h = 16 });
    _ = gpa;
    try std.testing.expectEqual(@as(f64, 100), s.mseAvg());
    try std.testing.expectApproxEqAbs(@as(f64, 28.1308), psnr(s.mseAvg()).?, 1e-4);
}

test "metrics: only pixels inside the rect count" {
    const gpa = std.testing.allocator;
    const a = try testImage(gpa, 32, 32, 2);
    defer gpa.free(a);
    const b = try gpa.dupe(u8, a);
    defer gpa.free(b);
    // 矩形の外だけ壊す
    for (0..32) |y| for (0..32) |x| {
        if (x >= 8 and x < 24 and y >= 8 and y < 24) continue;
        b[(y * 32 + x) * 3] ^= 0xff;
    };
    const s = try score(.{ .width = 32, .height = 32, .rgb = a }, .{ .width = 32, .height = 32, .rgb = b }, .{ .x = 8, .y = 8, .w = 16, .h = 16 });
    try std.testing.expectEqual(@as(f64, 0), s.mseAvg());
    try std.testing.expectApproxEqAbs(@as(f64, 1), s.ssimAll(), 1e-6);
}

test "metrics: noise lowers SSIM, symmetric in its arguments" {
    const gpa = std.testing.allocator;
    const a = try testImage(gpa, 32, 32, 3);
    defer gpa.free(a);
    const b = try gpa.dupe(u8, a);
    defer gpa.free(b);
    var prng: std.Random.DefaultPrng = .init(9);
    for (b) |*v| v.* = v.* +% prng.random().intRangeAtMost(u8, 0, 20);
    const ia: Image = .{ .width = 32, .height = 32, .rgb = a };
    const ib: Image = .{ .width = 32, .height = 32, .rgb = b };
    const r: Rect = .{ .x = 0, .y = 0, .w = 32, .h = 32 };
    const ab = try score(ia, ib, r);
    const ba = try score(ib, ia, r);
    try std.testing.expect(ab.ssimAll() < 0.999);
    try std.testing.expectEqual(ab.ssimAll(), ba.ssimAll());
    try std.testing.expectEqual(ab.mseAvg(), ba.mseAvg());
}

test "metrics: rejects mismatched sizes and bad rects" {
    var a = [_]u8{0} ** (16 * 16 * 3);
    const img: Image = .{ .width = 16, .height = 16, .rgb = &a };
    const other: Image = .{ .width = 8, .height = 32, .rgb = &a };
    try std.testing.expectError(error.SizeMismatch, score(img, other, .{ .x = 0, .y = 0, .w = 8, .h = 8 }));
    try std.testing.expectError(error.RectOutside, score(img, img, .{ .x = 10, .y = 0, .w = 8, .h = 8 }));
    try std.testing.expectError(error.RectTooSmall, score(img, img, .{ .x = 0, .y = 0, .w = 7, .h = 16 }));
}
