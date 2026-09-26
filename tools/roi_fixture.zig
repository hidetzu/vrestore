//! ROI 検出の回帰テスト・較正に使う合成素材を作り、結果を正解と照合する。
//!
//!   roi_fixture synth  <case> <out.rgb> <truth.json>   RGB24 の生フレームと正解を書く
//!   roi_fixture cutref <video> <truth.json> <out.png>  エンコード済み動画のフレームから参照画像を切る
//!   roi_fixture check  <truth.json> <detection.json>   dx / dy / IoU / reliable を判定する
//!
//! 実素材・他者のウォーターマークを使わずに済むよう、ウォーターマークはランダムな「文字風」グリフで描く
//! (フォントに依存しないので CI でも同じ絵になる)。
//!
//! <case> は key=value をカンマで並べたもの。既定値は `Case` を見る。例:
//!   name=pan-crf35,bg=pan,crf=35,opacity=1

const std = @import("std");
const Io = std.Io;
const video = @import("video");
const roi = @import("roi");

pub const Case = struct {
    name: []const u8 = "case",
    width: u32 = 640,
    height: u32 = 360,
    frames: u32 = 30,
    /// pan: 模様がパンする / cut: 毎フレーム別の模様 / flat: 動かない滑らかなグラデーション
    bg: enum { pan, cut, flat } = .pan,
    /// 1 フレームあたりのパン量 (px)
    pan_x: i32 = 7,
    pan_y: i32 = 3,
    /// ウォーターマークの左上。負なら右端・下端から数える
    x: i32 = -8,
    y: i32 = 6,
    lines: u32 = 3,
    chars: u32 = 12,
    /// グリフ列の周期。0 なら繰り返し無し。繰り返す文字列で「PSR は高いが位置が違う」を作る
    period: u32 = 0,
    /// 0 ならウォーターマークを焼かない（何も無い動画に参照画像だけ渡す）
    opacity: f32 = 1,
    /// 参照画像: full はウォーターマーク全体 + margin、part は 1 行目の先頭 `part_chars` 文字だけ
    ref: enum { full, part } = .full,
    part_chars: u32 = 3,
    /// part の開始文字。繰り返しの途中から切ると、同じ模様が左右に並ぶ
    part_offset: u32 = 0,
    margin: u32 = 6,
    /// 参照画像を切るフレーム
    ref_frame: u32 = 0,
    seed: u64 = 1,
    /// hit: 正しい位置で reliable / safe: reliable なら正しい位置 / reject: reliable=false
    expect: enum { hit, safe, reject } = .hit,
    /// ffmpeg に渡す crf。この値は build.zig と較正スクリプトが ffmpeg に渡すだけで、ここでは記録のみ
    crf: u32 = 23,
};

const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

const Truth = struct {
    case: []const u8,
    expect: []const u8,
    width: u32,
    height: u32,
    /// 参照画像として切り出す矩形 = 検出されるべき矩形
    ref_x: u32,
    ref_y: u32,
    ref_w: u32,
    ref_h: u32,
    ref_frame: u32,
    crf: u32,
    opacity: f32,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var err_buf: [512]u8 = undefined;
    var err: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    defer err.interface.flush() catch {};
    var out_buf: [512]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    defer out.interface.flush() catch {};

    if (args.len == 5 and std.mem.eql(u8, args[1], "synth")) {
        const c = try parseCase(args[2]);
        try synth(arena, io, c, args[3], args[4]);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "cutref")) {
        video.c.av_log_set_level(video.c.AV_LOG_QUIET);
        try cutref(arena, io, args[2], args[3], args[4]);
        return 0;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "check")) {
        // PASS の行は stdout（zig build では表示されない）、FAIL の行は stderr にも出して失敗文に載せる
        const code = try check(arena, io, &out.interface, args[2], args[3]);
        if (code != 0) try err.interface.writeAll(out.interface.buffered());
        return code;
    }
    try err.interface.writeAll("usage: roi_fixture synth <case> <out.rgb> <truth.json> | cutref <video> <truth.json> <out.png> | check <truth.json> <detection.json>\n");
    return 2;
}

pub fn parseCase(spec: []const u8) !Case {
    var c: Case = .{};
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadCase;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        var found = false;
        inline for (std.meta.fields(Case)) |f| {
            if (std.mem.eql(u8, k, f.name)) {
                found = true;
                @field(c, f.name) = switch (@typeInfo(f.type)) {
                    .int => try std.fmt.parseInt(f.type, v, 10),
                    .float => try std.fmt.parseFloat(f.type, v),
                    .@"enum" => std.meta.stringToEnum(f.type, v) orelse return error.BadCase,
                    .pointer => v,
                    else => @compileError("unsupported field"),
                };
            }
        }
        if (!found) return error.BadCase;
    }
    return c;
}

// ---- 描画 --------------------------------------------------------------------

const glyph_w = 5;
const glyph_h = 7;
const scale = 2;
const cell_w = glyph_w * scale + 2;
const cell_h = glyph_h * scale + 4;

/// ウォーターマークの 1 画素: 0 = 透明, 1 = 縁取り (黒), 2 = 塗り
fn watermarkMask(gpa: std.mem.Allocator, c: Case) !struct { w: u32, h: u32, px: []u8 } {
    const w = c.chars * cell_w + 2;
    const h = c.lines * cell_h + 2;
    const px = try gpa.alloc(u8, w * h);
    @memset(px, 0);
    for (0..c.lines) |line| {
        for (0..c.chars) |ch| {
            // 周期があるときは全行で同じ並びを繰り返す
            const id: u64 = if (c.period > 0) ch % c.period else line * c.chars + ch;
            var prng: std.Random.DefaultPrng = .init(c.seed *% 7919 +% id);
            const r = prng.random();
            for (0..glyph_h) |gy| for (0..glyph_w) |gx| {
                if (r.float(f32) >= 0.45) continue;
                for (0..scale) |sy| for (0..scale) |sx| {
                    const x = 1 + ch * cell_w + gx * scale + sx;
                    const y = 1 + line * cell_h + gy * scale + sy;
                    px[y * w + x] = 2;
                };
            };
        }
    }
    // 縁取り: 塗りに隣接する透明画素を黒にする（実物の透かしによくある形）
    for (1..h - 1) |y| for (1..w - 1) |x| {
        if (px[y * w + x] != 0) continue;
        const near = px[(y - 1) * w + x] == 2 or px[(y + 1) * w + x] == 2 or px[y * w + x - 1] == 2 or px[y * w + x + 1] == 2;
        if (near) px[y * w + x] = 1;
    };
    return .{ .w = w, .h = h, .px = px };
}

/// 滑らかな乱数模様 (value noise を 4 オクターブ)。0..1
fn noiseTexture(gpa: std.mem.Allocator, w: u32, h: u32, seed: u64) ![]f32 {
    const t = try gpa.alloc(f32, w * h);
    @memset(t, 0);
    var amp: f32 = 0.5;
    var cell: u32 = 32;
    var octave: u64 = 0;
    while (octave < 4) : (octave += 1) {
        const gw = w / cell + 2;
        const gh = h / cell + 2;
        const grid = try gpa.alloc(f32, gw * gh);
        defer gpa.free(grid);
        var prng: std.Random.DefaultPrng = .init(seed *% 31 +% octave);
        for (grid) |*g| g.* = prng.random().float(f32);
        for (0..h) |y| for (0..w) |x| {
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(cell));
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(cell));
            const ix: usize = @intFromFloat(fx);
            const iy: usize = @intFromFloat(fy);
            const tx = fx - @as(f32, @floatFromInt(ix));
            const ty = fy - @as(f32, @floatFromInt(iy));
            const a = grid[iy * gw + ix] * (1 - tx) + grid[iy * gw + ix + 1] * tx;
            const b = grid[(iy + 1) * gw + ix] * (1 - tx) + grid[(iy + 1) * gw + ix + 1] * tx;
            t[y * w + x] += amp * (a * (1 - ty) + b * ty);
        };
        amp /= 2;
        cell /= 2;
    }
    return t;
}

fn synth(gpa: std.mem.Allocator, io: Io, c: Case, out_path: []const u8, truth_path: []const u8) !void {
    const w = c.width;
    const h = c.height;
    const mask = try watermarkMask(gpa, c);
    const wx: u32 = @intCast(if (c.x < 0) @as(i32, @intCast(w - mask.w)) + c.x + 1 else c.x);
    const wy: u32 = @intCast(if (c.y < 0) @as(i32, @intCast(h - mask.h)) + c.y + 1 else c.y);
    if (wx + mask.w > w or wy + mask.h > h) return error.WatermarkOutsideFrame;

    // 背景: pan は大きな模様から窓をずらして切る。cut は毎フレーム別の seed
    const span_x: u32 = @abs(c.pan_x) * c.frames;
    const span_y: u32 = @abs(c.pan_y) * c.frames;
    const tw = w + span_x;
    const th = h + span_y;
    const tex = [3][]f32{
        try noiseTexture(gpa, tw, th, c.seed * 3 + 0),
        try noiseTexture(gpa, tw, th, c.seed * 3 + 1),
        try noiseTexture(gpa, tw, th, c.seed * 3 + 2),
    };

    const frame = try gpa.alloc(u8, w * h * 3);
    const file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .initStreaming(file, io, &buf);

    for (0..c.frames) |k| {
        const cut_tex = if (c.bg == .cut) [3][]f32{
            try noiseTexture(gpa, w, h, c.seed * 1000 + k * 3 + 0),
            try noiseTexture(gpa, w, h, c.seed * 1000 + k * 3 + 1),
            try noiseTexture(gpa, w, h, c.seed * 1000 + k * 3 + 2),
        } else undefined;
        // パンの向きが負なら模様の反対側から始める
        const ox: u32 = if (c.pan_x >= 0) @as(u32, @intCast(c.pan_x)) * @as(u32, @intCast(k)) else span_x - @abs(c.pan_x) * @as(u32, @intCast(k));
        const oy: u32 = if (c.pan_y >= 0) @as(u32, @intCast(c.pan_y)) * @as(u32, @intCast(k)) else span_y - @abs(c.pan_y) * @as(u32, @intCast(k));
        for (0..h) |y| for (0..w) |x| {
            var rgb: [3]f32 = undefined;
            for (0..3) |ch| rgb[ch] = switch (c.bg) {
                .pan => tex[ch][(y + oy) * tw + x + ox],
                .cut => cut_tex[ch][y * w + x],
                .flat => (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w)) * 0.6 +
                    @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h)) * 0.3 + 0.05 * @as(f32, @floatFromInt(ch))),
            } * 255;
            if (x >= wx and x < wx + mask.w and y >= wy and y < wy + mask.h) {
                const m = mask.px[(y - wy) * mask.w + (x - wx)];
                if (m != 0) {
                    const line = (y - wy) / cell_h;
                    const ink: [3]f32 = if (m == 1) .{ 0, 0, 0 } else if (line % 2 == 0) .{ 255, 32, 32 } else .{ 32, 96, 255 };
                    for (0..3) |ch| rgb[ch] = rgb[ch] * (1 - c.opacity) + ink[ch] * c.opacity;
                }
            }
            for (0..3) |ch| frame[(y * w + x) * 3 + ch] = @intFromFloat(std.math.clamp(@round(rgb[ch]), 0, 255));
        };
        try fw.interface.writeAll(frame);
    }
    try fw.interface.flush();

    const ref: Rect = switch (c.ref) {
        .full => expand(.{ .x = wx, .y = wy, .w = mask.w, .h = mask.h }, c.margin, w, h),
        .part => expand(.{ .x = wx + c.part_offset * cell_w, .y = wy, .w = c.part_chars * cell_w + 2, .h = cell_h + 2 }, c.margin, w, h),
    };
    const truth: Truth = .{
        .case = c.name,
        .expect = @tagName(c.expect),
        .width = w,
        .height = h,
        .ref_x = ref.x,
        .ref_y = ref.y,
        .ref_w = ref.w,
        .ref_h = ref.h,
        .ref_frame = c.ref_frame,
        .crf = c.crf,
        .opacity = c.opacity,
    };
    var jw: Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(truth, .{}, &jw.writer);
    try jw.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = truth_path, .data = jw.written() });
}

/// `r` を `m` px 広げ、画面内に収める
fn expand(r: Rect, m: u32, w: u32, h: u32) Rect {
    const x0 = r.x -| m;
    const y0 = r.y -| m;
    const x1 = @min(r.x + r.w + m, w);
    const y1 = @min(r.y + r.h + m, h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn readTruth(arena: std.mem.Allocator, io: Io, path: []const u8) !Truth {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16));
    return std.json.parseFromSliceLeaky(Truth, arena, data, .{});
}

fn cutref(arena: std.mem.Allocator, io: Io, video_path: []const u8, truth_path: []const u8, out_path: []const u8) !void {
    const t = try readTruth(arena, io, truth_path);
    var d = try video.Decoder.open(try arena.dupeZ(u8, video_path));
    defer d.close();
    const buf = try arena.alloc(u8, d.frameBytes());
    var f: ?video.Frame = null;
    for (0..t.ref_frame + 1) |_| f = (try d.next(buf)) orelse return error.RefFrameOutOfRange;
    const row = t.ref_w * 3;
    const crop = try arena.alloc(u8, row * t.ref_h);
    for (0..t.ref_h) |j| @memcpy(crop[j * row ..][0..row], buf[((t.ref_y + j) * t.width + t.ref_x) * 3 ..][0..row]);
    const png = try video.encodePng(arena, t.ref_w, t.ref_h, crop);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = png });
}

const DetectionJson = struct {
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    confidence: f64,
    psr: ?f64,
    margin: ?f64,
    peak: f64,
    frames_voted: u32,
    reliable: bool,
    reasons: []const []const u8,
};

/// 1 行で結果を出す。較正スクリプトもこの行を読む:
///   <PASS|FAIL> case=<name> expect=<e> dx=<> dy=<> iou=<> reliable=<> confidence=<> margin=<> psr=<> crf=<> opacity=<>
fn check(arena: std.mem.Allocator, io: Io, out: *Io.Writer, truth_path: []const u8, det_path: []const u8) !u8 {
    const t = try readTruth(arena, io, truth_path);
    const data = try Io.Dir.cwd().readFileAlloc(io, det_path, arena, .limited(1 << 16));
    const d = try std.json.parseFromSliceLeaky(DetectionJson, arena, data, .{});

    const dx = d.x - t.ref_x;
    const dy = d.y - t.ref_y;
    const i = roi.iou(d.x, d.y, d.width, d.height, t.ref_x, t.ref_y, t.ref_w, t.ref_h);
    const exact = dx == 0 and dy == 0 and d.width == t.ref_w and d.height == t.ref_h;
    const ok = if (std.mem.eql(u8, t.expect, "hit"))
        exact and d.reliable
    else if (std.mem.eql(u8, t.expect, "safe"))
        !d.reliable or exact
    else
        !d.reliable;

    try out.print("{s} case={s} expect={s} dx={d} dy={d} iou={d:.3} reliable={} confidence={d:.3} margin={d:.3} psr={d:.1} crf={d} opacity={d:.2}\n", .{
        if (ok) "PASS" else "FAIL", t.case, t.expect, dx, dy, i, d.reliable, d.confidence, d.margin orelse -1, d.psr orelse -1, t.crf, t.opacity,
    });
    return if (ok) 0 else 1;
}

test "parseCase" {
    const c = try parseCase("name=a,bg=cut,crf=35,opacity=0.5,x=-3,expect=safe");
    try std.testing.expectEqualStrings("a", c.name);
    try std.testing.expectEqual(.cut, c.bg);
    try std.testing.expectEqual(@as(u32, 35), c.crf);
    try std.testing.expectEqual(@as(f32, 0.5), c.opacity);
    try std.testing.expectEqual(@as(i32, -3), c.x);
    try std.testing.expectEqual(.safe, c.expect);
    try std.testing.expectError(error.BadCase, parseCase("nope=1"));
}
