//! 復元したフレームを H.264 の MP4 に書き出し、元の動画の音声をそのまま入れる（docs/adr/0013）。
//!
//! 符号化・多重化は FFmpeg (libav*) に任せる（docs/adr/0001）。ここが持つのは次の 3 つだけ:
//! - 各フレームの時刻は元の動画の値（デコーダの pts）をそのまま使う（可変フレームレートも崩さない）
//! - RGB → YUV は、デコーダ（video.zig）が YUV → RGB に使ったのと同じ swscale の既定で戻す。
//!   往復で元の YUV にほぼ戻るので、色の情報（原色・伝達特性・行列）は元のストリームの値を写す
//! - 音声は再符号化せず、元のパケットを時刻の順に混ぜて書く（stream copy）

const std = @import("std");
const video = @import("video.zig");
const c = video.c;

pub const Error = error{
    /// 出力ファイルを作れない
    CreateFailed,
    /// 幅か高さが奇数（H.264 の 4:2:0 は偶数しか持てない）
    OddSize,
    /// この FFmpeg に H.264 のエンコーダが無い
    NoEncoder,
    EncodeFailed,
    WriteFailed,
    /// 元の音声の形式を MP4 に入れられない（--audio none で音声なしにできる）
    AudioNotSupported,
    /// 元の動画を音声のために開けない
    OpenFailed,
    OutOfMemory,
};

pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.CreateFailed => "could not create the output file",
        error.OddSize => "H.264 (4:2:0) needs an even width and height; this video's is odd (use --raw instead)",
        error.NoEncoder => "this FFmpeg has no H.264 encoder (libx264)",
        error.EncodeFailed => "encoding failed",
        error.WriteFailed => "writing the output failed",
        error.AudioNotSupported => "the audio codec cannot go into MP4 as is; use --audio none to drop the audio",
        error.OpenFailed => "could not open the input again to copy its audio",
        error.OutOfMemory => "out of memory",
    };
}

pub const Options = struct {
    /// libx264 の crf（小さいほど高画質・大きい）
    crf: u8 = 18,
    preset: [:0]const u8 = "medium",
    /// 元の動画の音声を入れる
    audio: bool = true,
};

pub const Writer = struct {
    oc: *c.AVFormatContext,
    enc: *c.AVCodecContext,
    vst: *c.AVStream,
    sws: *c.SwsContext,
    frame: *c.AVFrame,
    pkt: *c.AVPacket,
    /// 入力の映像ストリームの time_base（Frame.pts の単位）
    src_tb: c.AVRational,
    /// 入力の 1 フレームの長さ（src_tb）。pts が分からないフレームに使う
    frame_ticks: i64,
    last_pts: ?i64 = null,
    audio: ?Audio,
    frames: u64 = 0,

    const Audio = struct {
        ic: *c.AVFormatContext,
        in_index: c_int,
        ost: *c.AVStream,
        pkt: *c.AVPacket,
        /// 読んだが、まだ書いていない（映像より先の時刻）パケットがある
        pending: bool = false,
        eof: bool = false,
        packets: u64 = 0,
    };

    /// `out_path` に MP4 を作る。映像の大きさ・time_base・色の情報は `d`（入力のデコーダ）から取る。
    /// 音声は `src_path` をもう一度開いて写す
    pub fn open(out_path: [:0]const u8, src_path: [:0]const u8, d: *const video.Decoder, opts: Options) Error!Writer {
        if (d.info.width % 2 != 0 or d.info.height % 2 != 0) return error.OddSize;
        var oc_opt: ?*c.AVFormatContext = null;
        if (c.avformat_alloc_output_context2(&oc_opt, null, "mp4", out_path.ptr) < 0 or oc_opt == null) return error.CreateFailed;
        const oc = oc_opt.?;
        errdefer c.avformat_free_context(oc);

        const codec = c.avcodec_find_encoder_by_name("libx264") orelse c.avcodec_find_encoder(c.AV_CODEC_ID_H264) orelse return error.NoEncoder;
        var enc_opt: ?*c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(&enc_opt);
        const enc = enc_opt.?;
        const in_par = d.stream.codecpar;
        enc.width = @intCast(d.info.width);
        enc.height = @intCast(d.info.height);
        enc.pix_fmt = c.AV_PIX_FMT_YUV420P;
        enc.time_base = d.stream.time_base;
        if (d.stream.avg_frame_rate.num > 0 and d.stream.avg_frame_rate.den > 0) enc.framerate = d.stream.avg_frame_rate;
        enc.sample_aspect_ratio = in_par.*.sample_aspect_ratio;
        enc.color_primaries = in_par.*.color_primaries;
        enc.color_trc = in_par.*.color_trc;
        enc.colorspace = in_par.*.color_space;
        enc.color_range = c.AVCOL_RANGE_MPEG; // swscale の既定の出力は limited
        if (oc.oformat.*.flags & c.AVFMT_GLOBALHEADER != 0) enc.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;

        var dict: ?*c.AVDictionary = null;
        defer c.av_dict_free(&dict);
        var crf_buf: [8]u8 = undefined;
        const crf = std.fmt.bufPrintZ(&crf_buf, "{d}", .{opts.crf}) catch unreachable;
        _ = c.av_dict_set(&dict, "crf", crf.ptr, 0);
        _ = c.av_dict_set(&dict, "preset", opts.preset.ptr, 0);
        if (c.avcodec_open2(enc, codec, &dict) < 0) return error.EncodeFailed;

        const vst: *c.AVStream = c.avformat_new_stream(oc, null) orelse return error.OutOfMemory;
        if (c.avcodec_parameters_from_context(vst.codecpar, enc) < 0) return error.EncodeFailed;
        vst.time_base = enc.time_base;
        vst.avg_frame_rate = d.stream.avg_frame_rate;

        var audio: ?Audio = null;
        errdefer if (audio) |*a| closeAudio(a);
        if (opts.audio) audio = try openAudio(oc, src_path);

        if (oc.oformat.*.flags & c.AVFMT_NOFILE == 0) {
            if (c.avio_open(&oc.pb, out_path.ptr, c.AVIO_FLAG_WRITE) < 0) return error.CreateFailed;
        }
        errdefer _ = c.avio_closep(&oc.pb);
        if (c.avformat_write_header(oc, null) < 0) return error.WriteFailed;

        const sws = c.sws_getContext(enc.width, enc.height, c.AV_PIX_FMT_RGB24, enc.width, enc.height, c.AV_PIX_FMT_YUV420P, c.SWS_BICUBIC | c.SWS_ACCURATE_RND | c.SWS_FULL_CHR_H_INT | c.SWS_FULL_CHR_H_INP, null, null, null) orelse return error.OutOfMemory;
        errdefer c.sws_freeContext(sws);
        var frame_opt: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(&frame_opt);
        const frame = frame_opt.?;
        frame.format = c.AV_PIX_FMT_YUV420P;
        frame.width = enc.width;
        frame.height = enc.height;
        if (c.av_frame_get_buffer(frame, 0) < 0) return error.OutOfMemory;
        const pkt: *c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;

        // 1 フレームの長さ: 平均フレームレートから。分からなければ 1 tick
        var frame_ticks: i64 = 1;
        if (d.stream.avg_frame_rate.num > 0) frame_ticks = @max(1, c.av_rescale_q(1, c.av_inv_q(d.stream.avg_frame_rate), d.stream.time_base));

        return .{ .oc = oc, .enc = enc, .vst = vst, .sws = sws, .frame = frame, .pkt = pkt, .src_tb = d.stream.time_base, .frame_ticks = frame_ticks, .audio = audio };
    }

    fn openAudio(oc: *c.AVFormatContext, src_path: [:0]const u8) Error!?Audio {
        var ic_opt: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&ic_opt, src_path.ptr, null, null) < 0) return error.OpenFailed;
        var ic = ic_opt.?;
        errdefer c.avformat_close_input(@ptrCast(&ic));
        if (c.avformat_find_stream_info(ic, null) < 0) return error.OpenFailed;
        const idx = c.av_find_best_stream(ic, c.AVMEDIA_TYPE_AUDIO, -1, -1, null, 0);
        if (idx < 0) {
            c.avformat_close_input(@ptrCast(&ic));
            return null; // 元に音声が無い
        }
        const ist = ic.streams[@intCast(idx)];
        if (c.avformat_query_codec(oc.oformat, ist.*.codecpar.*.codec_id, c.FF_COMPLIANCE_NORMAL) != 1) return error.AudioNotSupported;
        const ost: *c.AVStream = c.avformat_new_stream(oc, null) orelse return error.OutOfMemory;
        if (c.avcodec_parameters_copy(ost.codecpar, ist.*.codecpar) < 0) return error.OutOfMemory;
        ost.codecpar.*.codec_tag = 0;
        ost.time_base = ist.*.time_base;
        const pkt: *c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
        return .{ .ic = ic, .in_index = idx, .ost = ost, .pkt = pkt };
    }

    fn closeAudio(a: *Audio) void {
        var pkt: ?*c.AVPacket = a.pkt;
        c.av_packet_free(&pkt);
        var ic: ?*c.AVFormatContext = a.ic;
        c.avformat_close_input(&ic);
    }

    /// RGB24 のフレームを 1 枚書く。`pts` は入力のストリームの time_base（video.Frame.pts）
    pub fn write(w: *Writer, rgb: []const u8, pts: i64) Error!void {
        std.debug.assert(rgb.len == @as(usize, @intCast(w.enc.width)) * @as(usize, @intCast(w.enc.height)) * 3);
        if (c.av_frame_make_writable(w.frame) < 0) return error.OutOfMemory;
        const src = [4][*c]const u8{ rgb.ptr, null, null, null };
        const stride = [4]c_int{ w.enc.width * 3, 0, 0, 0 };
        if (c.sws_scale(w.sws, &src, &stride, 0, w.enc.height, &w.frame.data, &w.frame.linesize) != w.enc.height) return error.EncodeFailed;
        // 時刻が分からない・戻るフレームは、前のフレームの 1 フレーム後にする（エンコーダは単調増加を求める）
        var p = pts;
        if (w.last_pts) |last| {
            if (p == c.AV_NOPTS_VALUE or p <= last) p = last + w.frame_ticks;
        } else if (p == c.AV_NOPTS_VALUE) p = 0;
        w.last_pts = p;
        w.frame.pts = p;
        if (c.avcodec_send_frame(w.enc, w.frame) < 0) return error.EncodeFailed;
        try w.drain();
        w.frames += 1;
    }

    fn drain(w: *Writer) Error!void {
        while (true) {
            const r = c.avcodec_receive_packet(w.enc, w.pkt);
            if (r == video.averror_eagain or r == video.averror_eof) return;
            if (r < 0) return error.EncodeFailed;
            c.av_packet_rescale_ts(w.pkt, w.enc.time_base, w.vst.time_base);
            w.pkt.stream_index = w.vst.index;
            // この映像のパケットより前の時刻の音声を先に書く
            try w.writeAudioUntil(tsToSec(w.pkt.dts, w.vst.time_base));
            if (c.av_interleaved_write_frame(w.oc, w.pkt) < 0) return error.WriteFailed;
        }
    }

    fn writeAudioUntil(w: *Writer, sec: f64) Error!void {
        const a = if (w.audio) |*x| x else return;
        while (!a.eof) {
            if (!a.pending) {
                const r = c.av_read_frame(a.ic, a.pkt);
                if (r == video.averror_eof) {
                    a.eof = true;
                    return;
                }
                if (r < 0) return error.WriteFailed;
                if (a.pkt.stream_index != a.in_index) {
                    c.av_packet_unref(a.pkt);
                    continue;
                }
                a.pending = true;
            }
            const ist = a.ic.streams[@intCast(a.in_index)];
            const t = if (a.pkt.dts != c.AV_NOPTS_VALUE) a.pkt.dts else a.pkt.pts;
            if (t != c.AV_NOPTS_VALUE and tsToSec(t, ist.*.time_base) > sec) return;
            c.av_packet_rescale_ts(a.pkt, ist.*.time_base, a.ost.time_base);
            a.pkt.stream_index = a.ost.index;
            a.pkt.pos = -1;
            // av_interleaved_write_frame はパケットの中身を引き取る
            if (c.av_interleaved_write_frame(w.oc, a.pkt) < 0) return error.WriteFailed;
            a.pending = false;
            a.packets += 1;
        }
    }

    /// エンコーダに残ったフレームと、残りの音声を書いて閉じる
    pub fn finish(w: *Writer) Error!void {
        if (c.avcodec_send_frame(w.enc, null) < 0) return error.EncodeFailed;
        try w.drain();
        try w.writeAudioUntil(std.math.inf(f64));
        if (c.av_write_trailer(w.oc) < 0) return error.WriteFailed;
    }

    pub fn audioPackets(w: *const Writer) ?u64 {
        return if (w.audio) |a| a.packets else null;
    }

    pub fn close(w: *Writer) void {
        if (w.audio) |*a| closeAudio(a);
        var pkt: ?*c.AVPacket = w.pkt;
        c.av_packet_free(&pkt);
        var frame: ?*c.AVFrame = w.frame;
        c.av_frame_free(&frame);
        c.sws_freeContext(w.sws);
        var enc: ?*c.AVCodecContext = w.enc;
        c.avcodec_free_context(&enc);
        if (w.oc.oformat.*.flags & c.AVFMT_NOFILE == 0) _ = c.avio_closep(&w.oc.pb);
        c.avformat_free_context(w.oc);
        w.* = undefined;
    }
};

fn tsToSec(t: i64, tb: c.AVRational) f64 {
    if (t == c.AV_NOPTS_VALUE) return -std.math.inf(f64);
    return @as(f64, @floatFromInt(t)) * @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den));
}
