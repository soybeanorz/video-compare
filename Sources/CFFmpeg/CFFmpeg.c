#include "CFFmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct VCDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVBufferRef *hw_device;
    AVPacket *packet;
    AVFrame *frame;
    int stream_index;
    AVRational time_base;
    double duration;
    double fps;
    int width;
    int height;
};

static void set_error(char *error, int error_len, const char *message, int code) {
    if (!error || error_len <= 0) {
        return;
    }
    if (code < 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(code, detail, sizeof(detail));
        snprintf(error, (size_t)error_len, "%s: %s", message, detail);
    } else {
        snprintf(error, (size_t)error_len, "%s", message);
    }
}

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    return AV_PIX_FMT_NONE;
}

static double rational_to_double(AVRational value) {
    if (value.den == 0) {
        return 0;
    }
    return av_q2d(value);
}

static double timestamp_to_seconds(int64_t timestamp, AVRational time_base) {
    if (timestamp == AV_NOPTS_VALUE) {
        return 0;
    }
    return (double)timestamp * av_q2d(time_base);
}

static int output_frame(VCDecoder *decoder, VCDecodedFrame *out_frame) {
    if (!decoder || !out_frame) {
        return AVERROR(EINVAL);
    }
    memset(out_frame, 0, sizeof(*out_frame));

    if (decoder->frame->format != AV_PIX_FMT_VIDEOTOOLBOX || !decoder->frame->data[3]) {
        return AVERROR_EXTERNAL;
    }

    CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)decoder->frame->data[3];
    CVPixelBufferRetain(pixel_buffer);
    out_frame->pixelBuffer = pixel_buffer;
    out_frame->pts = timestamp_to_seconds(decoder->frame->best_effort_timestamp, decoder->time_base);
    out_frame->duration = decoder->fps > 0 ? 1.0 / decoder->fps : 0;
    out_frame->width = decoder->width;
    out_frame->height = decoder->height;
    return 1;
}

static int receive_available_frame(VCDecoder *decoder, VCDecodedFrame *out_frame) {
    while (1) {
        int result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return result;
        }
        if (result < 0) {
            return result;
        }
        result = output_frame(decoder, out_frame);
        av_frame_unref(decoder->frame);
        if (result > 0) {
            return result;
        }
        if (result < 0) {
            return result;
        }
    }
}

int vc_decoder_next(VCDecoder *decoder, VCDecodedFrame *out_frame) {
    if (!decoder || !out_frame) {
        return AVERROR(EINVAL);
    }

    int result = receive_available_frame(decoder, out_frame);
    if (result > 0) {
        return result;
    }

    while ((result = av_read_frame(decoder->format, decoder->packet)) >= 0) {
        if (decoder->packet->stream_index != decoder->stream_index) {
            av_packet_unref(decoder->packet);
            continue;
        }

        result = avcodec_send_packet(decoder->codec, decoder->packet);
        av_packet_unref(decoder->packet);
        if (result < 0 && result != AVERROR(EAGAIN)) {
            return result;
        }

        result = receive_available_frame(decoder, out_frame);
        if (result > 0) {
            return result;
        }
        if (result < 0 && result != AVERROR(EAGAIN)) {
            return result;
        }
    }

    avcodec_send_packet(decoder->codec, NULL);
    result = receive_available_frame(decoder, out_frame);
    return result > 0 ? result : 0;
}

VCDecoder *vc_decoder_open(const char *path, char *error, int error_len) {
    if (!path) {
        set_error(error, error_len, "missing path", 0);
        return NULL;
    }

    VCDecoder *decoder = calloc(1, sizeof(VCDecoder));
    if (!decoder) {
        set_error(error, error_len, "allocation failed", 0);
        return NULL;
    }
    decoder->stream_index = -1;

    int result = avformat_open_input(&decoder->format, path, NULL, NULL);
    if (result < 0) {
        set_error(error, error_len, "open input failed", result);
        vc_decoder_close(decoder);
        return NULL;
    }

    result = avformat_find_stream_info(decoder->format, NULL);
    if (result < 0) {
        set_error(error, error_len, "read stream info failed", result);
        vc_decoder_close(decoder);
        return NULL;
    }

    result = av_find_best_stream(decoder->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (result < 0) {
        set_error(error, error_len, "no video stream found", result);
        vc_decoder_close(decoder);
        return NULL;
    }
    decoder->stream_index = result;
    AVStream *stream = decoder->format->streams[decoder->stream_index];
    decoder->time_base = stream->time_base;

    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        set_error(error, error_len, "decoder not found", 0);
        vc_decoder_close(decoder);
        return NULL;
    }

    decoder->codec = avcodec_alloc_context3(codec);
    if (!decoder->codec) {
        set_error(error, error_len, "codec allocation failed", 0);
        vc_decoder_close(decoder);
        return NULL;
    }

    result = avcodec_parameters_to_context(decoder->codec, stream->codecpar);
    if (result < 0) {
        set_error(error, error_len, "copy codec parameters failed", result);
        vc_decoder_close(decoder);
        return NULL;
    }

    result = av_hwdevice_ctx_create(&decoder->hw_device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    if (result < 0) {
        set_error(error, error_len, "VideoToolbox device creation failed", result);
        vc_decoder_close(decoder);
        return NULL;
    }

    decoder->codec->hw_device_ctx = av_buffer_ref(decoder->hw_device);
    decoder->codec->get_format = get_hw_format;
    decoder->codec->thread_count = 1;

    result = avcodec_open2(decoder->codec, codec, NULL);
    if (result < 0) {
        set_error(error, error_len, "open VideoToolbox decoder failed", result);
        vc_decoder_close(decoder);
        return NULL;
    }

    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    if (!decoder->packet || !decoder->frame) {
        set_error(error, error_len, "packet/frame allocation failed", 0);
        vc_decoder_close(decoder);
        return NULL;
    }

    decoder->width = decoder->codec->width;
    decoder->height = decoder->codec->height;
    AVRational rate = stream->avg_frame_rate.num > 0 ? stream->avg_frame_rate : stream->r_frame_rate;
    decoder->fps = rational_to_double(rate);
    if (decoder->fps <= 1) {
        decoder->fps = 60;
    }

    if (stream->duration != AV_NOPTS_VALUE) {
        decoder->duration = timestamp_to_seconds(stream->duration, stream->time_base);
    } else if (decoder->format->duration != AV_NOPTS_VALUE) {
        decoder->duration = (double)decoder->format->duration / AV_TIME_BASE;
    } else {
        decoder->duration = 0;
    }

    return decoder;
}

int vc_decoder_seek(VCDecoder *decoder, double seconds, int exact, VCDecodedFrame *out_frame) {
    if (!decoder || !out_frame) {
        return AVERROR(EINVAL);
    }
    if (seconds < 0) {
        seconds = 0;
    }

    int64_t timestamp = (int64_t)(seconds / av_q2d(decoder->time_base));
    int result = av_seek_frame(decoder->format, decoder->stream_index, timestamp, AVSEEK_FLAG_BACKWARD);
    if (result < 0) {
        return result;
    }
    avcodec_flush_buffers(decoder->codec);

    double threshold = exact ? seconds - (0.5 / (decoder->fps > 0 ? decoder->fps : 60.0)) : -1.0;
    if (threshold < 0) {
        threshold = 0;
    }

    while ((result = vc_decoder_next(decoder, out_frame)) > 0) {
        if (!exact || out_frame->pts + 0.0001 >= threshold) {
            return 1;
        }
        vc_frame_release(out_frame);
    }
    return result;
}

void vc_decoder_close(VCDecoder *decoder) {
    if (!decoder) {
        return;
    }
    if (decoder->frame) {
        av_frame_free(&decoder->frame);
    }
    if (decoder->packet) {
        av_packet_free(&decoder->packet);
    }
    if (decoder->codec) {
        avcodec_free_context(&decoder->codec);
    }
    if (decoder->hw_device) {
        av_buffer_unref(&decoder->hw_device);
    }
    if (decoder->format) {
        avformat_close_input(&decoder->format);
    }
    free(decoder);
}

double vc_decoder_duration(VCDecoder *decoder) {
    return decoder ? decoder->duration : 0;
}

double vc_decoder_fps(VCDecoder *decoder) {
    return decoder ? decoder->fps : 0;
}

int vc_decoder_width(VCDecoder *decoder) {
    return decoder ? decoder->width : 0;
}

int vc_decoder_height(VCDecoder *decoder) {
    return decoder ? decoder->height : 0;
}

void vc_frame_release(VCDecodedFrame *frame) {
    if (!frame) {
        return;
    }
    if (frame->pixelBuffer) {
        CVPixelBufferRelease(frame->pixelBuffer);
    }
    memset(frame, 0, sizeof(*frame));
}
