//! 局所の optical flow で、別のフレームの実画素を運ぶ（`--temporal auto` の追加の候補、docs/adr/0018）。
//!
//! 画面全体の動き（temporal.zig）では、動く人・物の模様は運べない。ここでは ROI の周りだけで flow を求め、
//! 隠れた各画素から flow の鎖を前後にたどり、ウォーターマークの外に出たフレームの画素を候補にする。
//! 次をすべて満たした画素だけを戻したと数える（どれかを緩めると、実写で外れが 12% 台に増えた。SPEC §4）:
//!
//! 1. 大きな局所の動き: ROI の周りの帯の輝度の変化（軽い関門）と、flow の大きさ（90 パーセンタイルの平均 ≥ 1.5 px/フレーム）
//! 2. 鎖: 前後それぞれ最大 45 フレーム、一歩ごとに往復のずれ ≤ 0.5 px（合わなくなったらその先はたどらない）。画面の端から 8 px 以内には入らない
//! 3. 借りる元: ウォーターマーク（マスクで隠した画素、無ければ ROI + 8 px、temporal.Guard）の外で、flow を求めた範囲の中
//! 4. 候補: 5 枚以上、過去と未来の両方を含み、中央値からのずれ（R/G/B の最大）≤ 8。値は中央値
//! 5. 実行時の疑似チェック: ROI の隣の、ウォーターマークの無い 2 か所（おとり）でも同じことをし、採った画素を実際の入力と比べる。
//!    どちらのおとりでも 100 画素以上を採り、外れ（誤差 > 32）が 0.5% 以下のフレームでだけ、本物の ROI の候補を採る
//!
//! 最初の条件（3 枚・ずれ 12・往復 1 px・おとり 1 か所で外れ 1%）では、実写の疑似チェックで画面の端の位置の外れが 11.8% だった（SPEC §4）
//!
//! この module は FFmpeg と SDL に依存しない。

const std = @import("std");
const flow = @import("flow.zig");
const temporal = @import("temporal.zig");
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;

pub const Rect = temporal.Rect;

pub const Params = struct {
    /// 前後にたどるフレーム数の上限
    k: u32 = 45,
    min_candidates: u32 = 5,
    max_spread: f32 = 8,
    max_fb: f32 = 0.5,
    /// 画面の端からこの px 以内の位置は借りない（端では flow の窓が切れて当てにならない）
    border: u32 = 8,
    /// 軽い関門: 帯の輝度の変化の平均（前後 15 フレーム）
    min_ring_change: f32 = 3,
    /// flow の関門: 帯の flow の大きさの 90 パーセンタイルの、前後 k フレームの平均（px/フレーム）
    min_motion: f32 = 1.5,
    /// おとりの数（すべてが合格したフレームでだけ本物の候補を採る）
    decoys: u32 = 2,
    decoy_min_accepted: u32 = 100,
    decoy_max_wrong: f32 = 0.005,
    wrong_error: f32 = 32,
    flow: flow.Params = .{},
};

/// 隣り合うフレームの flow（範囲の座標、ウォーターマークとおとりの中は周りから補ったもの）
pub const Pair = struct {
    fw: flow.Field,
    bw: flow.Field,

    pub fn deinit(p: Pair, gpa: std.mem.Allocator) void {
        p.fw.deinit(gpa);
        p.bw.deinit(gpa);
    }
};

pub const Stats = struct {
    frames: u64 = 0,
    /// 動きが小さく試さなかった（軽い関門 / flow の関門）
    gated_light: u64 = 0,
    gated_motion: u64 = 0,
    /// おとりで外れが多い・採れる画素が足りず、本物の候補を採らなかった
    decoy_failed: u64 = 0,
    decoy_accepted: u64 = 0,
    decoy_wrong: u64 = 0,
    accepted: u64 = 0,
    rejected: u64 = 0,
    pairs_computed: u64 = 0,

    pub fn merge(a: *Stats, b: Stats) void {
        inline for (std.meta.fields(Stats)) |f| @field(a, f.name) += @field(b, f.name);
    }
};

/// 動画ごとに決まる配置: flow を求める範囲、おとり、借りない画素
pub const Session = struct {
    gpa: std.mem.Allocator,
    region: flow.Region,
    roi: Rect,
    decoy: [2]Rect,
    n_decoys: u32,
    /// 範囲の画素ごと: ウォーターマーク（借りない、本物の ROI の穴）
    wm: []bool,
    /// 範囲の画素ごと: おとり + 3 px（おとりの鎖では借りない）
    dg: []bool,
    /// 範囲の画素ごと: flow の窓の計算に使わない画素（wm ∪ dg）
    ignore: []bool,
    /// 範囲の画素ごと: flow を周りから補う画素（wm ∪ dg を、flow の窓の半径 + 1 px 広げたもの。
    /// 窓が止まったウォーターマークにかかる画素の flow は、止まった側に引っぱられて当てにならない）
    hole: []bool,
    frame_w: u32,
    frame_h: u32,
    p: Params,

    /// おとりを置く場所が無ければ null（局所の方式は使わない）
    pub fn init(gpa: std.mem.Allocator, roi: Rect, guard: temporal.Guard, frame_w: u32, frame_h: u32, p: Params) !?Session {
        const a = guard.area;
        const gap: u32 = 8;
        // おとり: ROI と同じ大きさで、守る範囲の下・上・右・左のうち画面に収まる最初の所
        const cands = [_]?[2]i64{
            .{ roi.x, @as(i64, a.y) + a.h + gap },
            .{ roi.x, @as(i64, a.y) - gap - roi.h },
            .{ @as(i64, a.x) + a.w + gap, roi.y },
            .{ @as(i64, a.x) - gap - roi.w, roi.y },
        };
        var decoys: [2]Rect = undefined;
        var nd: u32 = 0;
        for (cands) |c| {
            if (nd == @min(p.decoys, 2)) break;
            const xy = c.?;
            if (xy[0] < 3 or xy[1] < 3 or xy[0] + roi.w + 3 > frame_w or xy[1] + roi.h + 3 > frame_h) continue;
            decoys[nd] = .{ .x = @intCast(xy[0]), .y = @intCast(xy[1]), .w = roi.w, .h = roi.h };
            nd += 1;
        }
        if (nd < p.decoys) return null;
        const margin: u32 = 24;
        var bx0 = a.x;
        var by0 = a.y;
        var bx1 = a.x + a.w;
        var by1 = a.y + a.h;
        for (decoys[0..nd]) |dcy| {
            bx0 = @min(bx0, dcy.x);
            by0 = @min(by0, dcy.y);
            bx1 = @max(bx1, dcy.x + dcy.w);
            by1 = @max(by1, dcy.y + dcy.h);
        }
        const x0 = bx0 -| margin;
        const y0 = by0 -| margin;
        const x1 = @min(frame_w, bx1 + margin);
        const y1 = @min(frame_h, by1 + margin);
        const region: flow.Region = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        const n = @as(usize, region.w) * region.h;
        const wm = try gpa.alloc(bool, n);
        errdefer gpa.free(wm);
        const dg = try gpa.alloc(bool, n);
        errdefer gpa.free(dg);
        const hole = try gpa.alloc(bool, n);
        errdefer gpa.free(hole);
        const ignore = try gpa.alloc(bool, n);
        for (0..region.h) |y| for (0..region.w) |x| {
            const gx: i64 = @intCast(region.x + x);
            const gy: i64 = @intCast(region.y + y);
            const i = y * region.w + x;
            const in_roi = gx >= roi.x and gx < @as(i64, roi.x) + roi.w and gy >= roi.y and gy < @as(i64, roi.y) + roi.h;
            wm[i] = in_roi or guard.blocks(gx, gy);
            dg[i] = false;
            for (decoys[0..nd]) |dcy| {
                if (gx >= @as(i64, dcy.x) - 3 and gx < @as(i64, dcy.x) + dcy.w + 3 and gy >= @as(i64, dcy.y) - 3 and gy < @as(i64, dcy.y) + dcy.h + 3) dg[i] = true;
            }
            ignore[i] = wm[i] or dg[i];
        };
        // flow の窓（半径 p.flow.radius）がウォーターマーク・おとりにかかる画素も補う側に入れる
        const grow: i64 = @as(i64, p.flow.radius) + 1;
        for (0..region.h) |y| for (0..region.w) |x| {
            var any = false;
            var dy: i64 = -grow;
            while (dy <= grow and !any) : (dy += 1) {
                var dx: i64 = -grow;
                while (dx <= grow) : (dx += 1) {
                    const yy = @as(i64, @intCast(y)) + dy;
                    const xx = @as(i64, @intCast(x)) + dx;
                    if (xx < 0 or yy < 0 or xx >= region.w or yy >= region.h) continue;
                    const j = @as(usize, @intCast(yy)) * region.w + @as(usize, @intCast(xx));
                    if (wm[j] or dg[j]) {
                        any = true;
                        break;
                    }
                }
            }
            hole[y * region.w + x] = any;
        };
        return .{ .gpa = gpa, .region = region, .roi = roi, .decoy = decoys, .n_decoys = nd, .wm = wm, .dg = dg, .ignore = ignore, .hole = hole, .frame_w = frame_w, .frame_h = frame_h, .p = p };
    }

    pub fn deinit(s: Session) void {
        s.gpa.free(s.wm);
        s.gpa.free(s.dg);
        s.gpa.free(s.hole);
        s.gpa.free(s.ignore);
    }

    /// 軽い関門に使う、隣り合うフレームの帯（穴の外）の輝度の変化の平均（2 px おきに見る）
    pub fn ringChange(s: Session, a: []const u8, b: []const u8) f32 {
        var sum: f64 = 0;
        var n: u64 = 0;
        var y: usize = 0;
        while (y < s.region.h) : (y += 2) {
            var x: usize = 0;
            while (x < s.region.w) : (x += 2) {
                if (s.hole[y * s.region.w + x]) continue;
                const i = ((s.region.y + y) * s.frame_w + s.region.x + x) * 3;
                for (0..3) |c| sum += @abs(@as(f64, @floatFromInt(a[i + c])) - @as(f64, @floatFromInt(b[i + c])));
                n += 3;
            }
        }
        return if (n == 0) 0 else @floatCast(sum / @as(f64, @floatFromInt(n)));
    }

    /// フレーム a → b と b → a の flow（穴の中は周りから補う）
    pub fn pair(s: Session, a: []const u8, b: []const u8) !Pair {
        const la = try flow.lumaOf(s.gpa, a, s.frame_w, s.region);
        defer la.deinit(s.gpa);
        const lb = try flow.lumaOf(s.gpa, b, s.frame_w, s.region);
        defer lb.deinit(s.gpa);
        const fw = try flow.dense(s.gpa, la, lb, s.ignore, s.p.flow);
        errdefer fw.deinit(s.gpa);
        const bw = try flow.dense(s.gpa, lb, la, s.ignore, s.p.flow);
        flow.complete(fw, s.hole, 200);
        flow.complete(bw, s.hole, 200);
        return .{ .fw = fw, .bw = bw };
    }

    fn motionOf(s: Session, f: flow.Field) f32 {
        var mags: std.ArrayList(f32) = .empty;
        defer mags.deinit(s.gpa);
        var y: usize = 0;
        while (y < f.h) : (y += 2) {
            var x: usize = 0;
            while (x < f.w) : (x += 2) {
                const i = y * f.w + x;
                if (s.hole[i]) continue;
                mags.append(s.gpa, std.math.hypot(f.u[i], f.v[i])) catch return 0;
            }
        }
        if (mags.items.len == 0) return 0;
        std.mem.sort(f32, mags.items, {}, std.sort.asc(f32));
        // 90 パーセンタイル: 止まった背景の上を人・物が動く場面では、帯の大半は動かないので中央値は 0 になる
        return mags.items[mags.items.len * 9 / 10];
    }

    const Candidate = struct { px: [3]f32, dt: i16 };

    fn sampleRgb(s: Session, rgb: []const u8, x: f32, y: f32) [3]f32 {
        const fx = std.math.clamp(x, 0, @as(f32, @floatFromInt(s.frame_w - 1)));
        const fy = std.math.clamp(y, 0, @as(f32, @floatFromInt(s.frame_h - 1)));
        const x0: usize = @intFromFloat(@floor(fx));
        const y0: usize = @intFromFloat(@floor(fy));
        const x1 = @min(x0 + 1, s.frame_w - 1);
        const y1 = @min(y0 + 1, s.frame_h - 1);
        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));
        var out: [3]f32 = undefined;
        for (0..3) |c| {
            const p00: f32 = @floatFromInt(rgb[(y0 * s.frame_w + x0) * 3 + c]);
            const p10: f32 = @floatFromInt(rgb[(y0 * s.frame_w + x1) * 3 + c]);
            const p01: f32 = @floatFromInt(rgb[(y1 * s.frame_w + x0) * 3 + c]);
            const p11: f32 = @floatFromInt(rgb[(y1 * s.frame_w + x1) * 3 + c]);
            out[c] = (1 - ty) * ((1 - tx) * p00 + tx * p10) + ty * ((1 - tx) * p01 + tx * p11);
        }
        return out;
    }

    /// 画素 (x, y)（画面の座標）から鎖を前後にたどり、`own`（範囲の画素ごと、借りない）の外に出たフレームの値を集める
    fn gather(s: Session, frames: []const []const u8, pairs: []const ?Pair, target: usize, x: u32, y: u32, own: []const bool, buf: []Candidate) usize {
        var n: usize = 0;
        const rw: f32 = @floatFromInt(s.region.w);
        const rh: f32 = @floatFromInt(s.region.h);
        for ([_]i64{ -1, 1 }) |sign| {
            var px: f32 = @floatFromInt(x - s.region.x);
            var py: f32 = @floatFromInt(y - s.region.y);
            var step: i64 = 1;
            while (step <= s.p.k) : (step += 1) {
                const k0 = @as(i64, @intCast(target)) + sign * (step - 1);
                const k1 = @as(i64, @intCast(target)) + sign * step;
                if (k1 < 0 or k1 >= frames.len) break;
                const pi: usize = @intCast(@min(k0, k1));
                const pr = pairs[pi] orelse break;
                const f = if (sign < 0) pr.bw else pr.fw; // k0 → k1
                const g = if (sign < 0) pr.fw else pr.bw; // k1 → k0（往復の確かめ）
                const d = f.sample(px, py);
                const nx = px + d[0];
                const ny = py + d[1];
                if (nx < 0 or ny < 0 or nx > rw - 1 or ny > rh - 1) break;
                // 画面の端の近くは借りない
                const gxf = nx + @as(f32, @floatFromInt(s.region.x));
                const gyf = ny + @as(f32, @floatFromInt(s.region.y));
                const bd: f32 = @floatFromInt(s.p.border);
                if (gxf < bd or gyf < bd or gxf > @as(f32, @floatFromInt(s.frame_w)) - 1 - bd or gyf > @as(f32, @floatFromInt(s.frame_h)) - 1 - bd) break;
                const e = g.sample(nx, ny);
                if (std.math.hypot(nx + e[0] - px, ny + e[1] - py) > s.p.max_fb) break;
                px = nx;
                py = ny;
                const ix: usize = @intFromFloat(@round(px));
                const iy: usize = @intFromFloat(@round(py));
                const i = iy * s.region.w + ix;
                if (own[i] or s.wm[i]) continue; // まだ隠れている（またはウォーターマーク）
                if (n < buf.len) {
                    buf[n] = .{ .px = s.sampleRgb(frames[@intCast(k1)], px + @as(f32, @floatFromInt(s.region.x)), py + @as(f32, @floatFromInt(s.region.y))), .dt = @intCast(sign * step) };
                    n += 1;
                }
            }
        }
        return n;
    }

    /// 候補から値を決める。条件を満たさなければ null
    fn decide(s: Session, c: []Candidate) ?[3]f32 {
        if (c.len < s.p.min_candidates) return null;
        var past = false;
        var future = false;
        for (c) |x| {
            if (x.dt < 0) past = true else future = true;
        }
        if (!past or !future) return null;
        var med: [3]f32 = undefined;
        var tmp: [2 * 256]f32 = undefined;
        for (0..3) |ch| {
            for (c, 0..) |x, i| tmp[i] = x.px[ch];
            std.mem.sort(f32, tmp[0..c.len], {}, std.sort.asc(f32));
            med[ch] = if (c.len % 2 == 1) tmp[c.len / 2] else (tmp[c.len / 2 - 1] + tmp[c.len / 2]) / 2;
        }
        for (c) |x| for (0..3) |ch| {
            if (@abs(x.px[ch] - med[ch]) > s.p.max_spread) return null;
        };
        return med;
    }

    fn nearestDt(c: []const Candidate) i16 {
        var best: i16 = c[0].dt;
        for (c) |x| if (@abs(x.dt) < @abs(best)) {
            best = x.dt;
        };
        return best;
    }

    /// フレーム `target` の ROI のうち、まだ戻せていない（unrecovered）ウォーターマークの画素を、局所の flow で戻す。
    /// `pairs[i]` はフレーム i と i+1 の flow（null なら必要なときに求めて入れる。呼ぶ側が持ち、使い回す）。
    /// `ring[i]` はフレーム i と i+1 の帯の変化（ringChange）。`detail` は ROI の画素ごと（temporal.Detail）
    pub fn recover(s: Session, frames: []const []const u8, pairs: []?Pair, ring: []const f32, target: usize, out: []u8, prov: []Provenance, detail: []temporal.Detail) !Stats {
        var st: Stats = .{ .frames = 1 };
        const n = frames.len;
        std.debug.assert(pairs.len == n - 1 and ring.len == n - 1);
        // 1. 軽い関門（前後 15 フレーム）
        const lo15 = target -| 15;
        const hi15 = @min(n - 1, target + 15);
        var rsum: f32 = 0;
        var rcnt: f32 = 0;
        for (lo15..hi15) |i| {
            rsum += ring[i];
            rcnt += 1;
        }
        if (rcnt == 0 or rsum / rcnt < s.p.min_ring_change) {
            st.gated_light = 1;
            return st;
        }
        // 2. flow（必要な分だけ）と flow の関門
        const lo = target -| s.p.k;
        const hi = @min(n - 1, target + s.p.k);
        var msum: f32 = 0;
        var mcnt: f32 = 0;
        for (lo..hi) |i| {
            if (pairs[i] == null) {
                pairs[i] = try s.pair(frames[i], frames[i + 1]);
                st.pairs_computed += 1;
            }
            msum += s.motionOf(pairs[i].?.fw);
            mcnt += 1;
        }
        if (mcnt == 0 or msum / mcnt < s.p.min_motion) {
            st.gated_motion = 1;
            return st;
        }
        var buf: [2 * 256]Candidate = undefined;
        // 3. おとりで確かめる
        const tf = frames[target];
        var all_pass = true;
        for (s.decoy[0..s.n_decoys]) |dcy| {
            var acc: u64 = 0;
            var wrong: u64 = 0;
            for (dcy.y..dcy.y + dcy.h) |y| for (dcy.x..dcy.x + dcy.w) |x| {
                const m = s.gather(frames, pairs, target, @intCast(x), @intCast(y), s.dg, &buf);
                const v = s.decide(buf[0..m]) orelse continue;
                acc += 1;
                const i = (y * s.frame_w + x) * 3;
                var err: f32 = 0;
                for (0..3) |c| err = @max(err, @abs(v[c] - @as(f32, @floatFromInt(tf[i + c]))));
                if (err > s.p.wrong_error) wrong += 1;
            };
            st.decoy_accepted += acc;
            st.decoy_wrong += wrong;
            const rate = if (acc == 0) 1 else @as(f32, @floatFromInt(wrong)) / @as(f32, @floatFromInt(acc));
            // どのおとりも合格すること
            if (acc < s.p.decoy_min_accepted or rate > s.p.decoy_max_wrong) all_pass = false;
        }
        if (!all_pass) {
            st.decoy_failed = 1;
            return st;
        }
        // 4. 本物の ROI
        const roi = s.roi;
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
            const pi = y * s.frame_w + x;
            if (prov[pi] != .unrecovered) continue;
            const ri = (y - s.region.y) * s.region.w + (x - s.region.x);
            if (!s.wm[ri]) continue;
            const m = s.gather(frames, pairs, target, @intCast(x), @intCast(y), s.wm, &buf);
            if (m == 0) continue;
            const k = (y - roi.y) * roi.w + (x - roi.x);
            if (s.decide(buf[0..m])) |v| {
                for (0..3) |c| out[pi * 3 + c] = @intFromFloat(std.math.clamp(@round(v[c]), 0, 255));
                prov[pi] = .temporal_real;
                detail[k] = .{ .class = .accepted, .src = nearestDt(buf[0..m]), .kind = .local };
                st.accepted += 1;
            } else {
                if (detail[k].class == .none) detail[k] = .{ .class = .rejected, .src = nearestDt(buf[0..m]), .kind = .local };
                st.rejected += 1;
            }
        };
        return st;
    }
};

// ---- tests -------------------------------------------------------------------

const W = 160;
const H = 120;

/// 止まった背景（滑らかな模様）の上を、模様のある半径 `radius` の円板が 1 フレームに (vx, vy) px 動く。n フレーム
fn movingDisc(gpa: std.mem.Allocator, n: usize, vx: f32, vy: f32, radius: f32) ![][]u8 {
    const frames = try gpa.alloc([]u8, n);
    for (frames, 0..) |*f, k| {
        f.* = try gpa.alloc(u8, W * H * 3);
        const cx = 20 + vx * @as(f32, @floatFromInt(k));
        const cy = 60 + vy * @as(f32, @floatFromInt(k));
        for (0..H) |y| for (0..W) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            var v: [3]f32 = .{ 90 + 30 * @sin(fx / 9) * @cos(fy / 11), 110 + 25 * @cos(fx / 13), 100 + 20 * @sin(fy / 8) };
            const dx = fx - cx;
            const dy = fy - cy;
            if (dx * dx + dy * dy < radius * radius) {
                // 円板の模様は円板と一緒に動く
                v = .{ 150 + 40 * @sin(dx / 6) * @cos(dy / 7), 120 + 35 * @cos((dx + dy) / 9), 90 + 30 * @sin((dx - 2 * dy) / 11) };
            }
            for (0..3) |c| f.*[(y * W + x) * 3 + c] = @intFromFloat(std.math.clamp(v[c], 0, 255));
        };
    }
    return frames;
}

fn freeFrames(gpa: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |f| gpa.free(f);
    gpa.free(frames);
}

const Fixture = struct {
    session: Session,
    pairs: []?Pair,
    ring: []f32,
    fn init(gpa: std.mem.Allocator, frames: []const []u8, roi: Rect, p: Params) !Fixture {
        const s = (try Session.init(gpa, roi, .{ .area = roi }, W, H, p)).?;
        const pairs = try gpa.alloc(?Pair, frames.len - 1);
        @memset(pairs, null);
        const ring = try gpa.alloc(f32, frames.len - 1);
        for (ring, 0..) |*r, i| r.* = s.ringChange(frames[i], frames[i + 1]);
        return .{ .session = s, .pairs = pairs, .ring = ring };
    }
    fn deinit(f: Fixture, gpa: std.mem.Allocator) void {
        for (f.pairs) |p| if (p) |pp| pp.deinit(gpa);
        gpa.free(f.pairs);
        gpa.free(f.ring);
        f.session.deinit();
    }
};

/// ROI（とその周り）を塗りつぶした入力で、フレーム t を局所の flow で戻す。戻した画素の数と、正解との差の最大を返す
fn runDisc(gpa: std.mem.Allocator, truth: []const []u8, roi: Rect, t: usize, p: Params) !struct { stats: Stats, worst: f32 } {
    const frames = try gpa.alloc([]u8, truth.len);
    defer freeFrames(gpa, frames);
    for (frames, truth) |*f, tr| {
        f.* = try gpa.dupe(u8, tr);
        for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
            f.*[(y * W + x) * 3 ..][0..3].* = .{ 255, 0, 255 };
        };
    }
    const fx = try Fixture.init(gpa, frames, roi, p);
    defer fx.deinit(gpa);
    const out = try gpa.dupe(u8, frames[t]);
    defer gpa.free(out);
    const prov = try gpa.alloc(Provenance, W * H);
    defer gpa.free(prov);
    @memset(prov, .original);
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        prov[y * W + x] = .unrecovered;
    };
    const detail = try gpa.alloc(temporal.Detail, @as(usize, roi.w) * roi.h);
    defer gpa.free(detail);
    @memset(detail, .{});
    const st = try fx.session.recover(frames, fx.pairs, fx.ring, t, out, prov, detail);
    var worst: f32 = 0;
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        if (prov[y * W + x] != .temporal_real) continue;
        for (0..3) |c| worst = @max(worst, @abs(@as(f32, @floatFromInt(out[(y * W + x) * 3 + c])) - @as(f32, @floatFromInt(truth[t][(y * W + x) * 3 + c]))));
        try std.testing.expect(detail[(y - roi.y) * roi.w + x - roi.x].kind == .local);
    };
    return .{ .stats = st, .worst = worst };
}

test "local_temporal: brings back the pixels of a large moving object from the frames where they were visible" {
    // ROI と周りの帯がすべて動く円板の上（手持ちのカメラで周りも一緒に動くのと同じ）: 周りから補った flow が正しい
    const gpa = std.testing.allocator;
    const truth = try movingDisc(gpa, 31, 3, 0, 200);
    defer freeFrames(gpa, truth);
    const r = try runDisc(gpa, truth, .{ .x = 70, .y = 50, .w = 20, .h = 20 }, 15, .{ .k = 15, .min_ring_change = 0.5, .min_motion = 1.0, .decoy_min_accepted = 1 });

    // 実測（今の条件）: 31 画素、正解との差は最大 2
    try std.testing.expect(r.stats.accepted >= 20);
    try std.testing.expect(r.worst <= 32);
}

test "local_temporal: on the last frame only the past is visible, so it takes nothing" {
    // 大きな円板が動く（上のテストと同じ）が、表示中のフレームが最後: 未来の候補が 1 枚も無い
    const gpa = std.testing.allocator;
    const truth = try movingDisc(gpa, 31, 3, 0, 200);
    defer freeFrames(gpa, truth);
    const r = try runDisc(gpa, truth, .{ .x = 70, .y = 50, .w = 20, .h = 20 }, 30, .{ .k = 15, .min_ring_change = 0.5, .min_motion = 1.0, .decoy_min_accepted = 0, .decoy_max_wrong = 1 });
    try std.testing.expectEqual(@as(u64, 0), r.stats.accepted);
}

test "local_temporal: where the surroundings move differently, it may take less but does not take wrong pixels" {
    // 小さな円板が止まった背景の上を動く: ROI の中の flow は周りの動きが混ざり正しくない。候補がそろわず採らないか、採っても外れない
    const gpa = std.testing.allocator;
    const truth = try movingDisc(gpa, 31, 3, 0, 30);
    defer freeFrames(gpa, truth);
    const r = try runDisc(gpa, truth, .{ .x = 70, .y = 50, .w = 20, .h = 20 }, 15, .{ .k = 15, .min_ring_change = 0.5, .min_motion = 1.0, .decoy_min_accepted = 1 });
    try std.testing.expect(r.worst <= 32);
}

test "local_temporal: does not try when nothing moves, and does not take when the decoy check fails" {
    const gpa = std.testing.allocator;
    const roi: Rect = .{ .x = 70, .y = 50, .w = 20, .h = 20 };
    // 動かない
    const still = try movingDisc(gpa, 21, 0, 0, 30);
    defer freeFrames(gpa, still);
    const fx = try Fixture.init(gpa, still, roi, .{ .k = 10 });
    defer fx.deinit(gpa);
    const out = try gpa.dupe(u8, still[10]);
    defer gpa.free(out);
    var prov = [_]Provenance{.original} ** (W * H);
    for (roi.y..roi.y + roi.h) |y| for (roi.x..roi.x + roi.w) |x| {
        prov[y * W + x] = .unrecovered;
    };
    var detail = [_]temporal.Detail{.{}} ** (20 * 20);
    const st = try fx.session.recover(still, fx.pairs, fx.ring, 10, out, &prov, &detail);
    try std.testing.expectEqual(@as(u64, 1), st.gated_light);
    try std.testing.expectEqual(@as(u64, 0), st.pairs_computed);

    // 動いているが、おとりで採れる画素の数の条件を満たせない（上限を大きくする）と、本物も採らない
    const moving = try movingDisc(gpa, 31, 3, 0, 30);
    defer freeFrames(gpa, moving);
    const fx2 = try Fixture.init(gpa, moving, roi, .{ .k = 15, .min_ring_change = 0.5, .min_motion = 1.0, .decoy_min_accepted = 1_000_000 });
    defer fx2.deinit(gpa);
    const st2 = try fx2.session.recover(moving, fx2.pairs, fx2.ring, 15, out, &prov, &detail);
    try std.testing.expectEqual(@as(u64, 1), st2.decoy_failed);
    try std.testing.expectEqual(@as(u64, 0), st2.accepted);
}
