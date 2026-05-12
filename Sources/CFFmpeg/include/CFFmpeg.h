#pragma once

#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VCDecoder VCDecoder;

typedef struct VCDecodedFrame {
    CVPixelBufferRef pixelBuffer;
    double pts;
    double duration;
    int width;
    int height;
} VCDecodedFrame;

VCDecoder *vc_decoder_open(const char *path, char *error, int error_len);
void vc_decoder_close(VCDecoder *decoder);

double vc_decoder_duration(VCDecoder *decoder);
double vc_decoder_fps(VCDecoder *decoder);
int vc_decoder_width(VCDecoder *decoder);
int vc_decoder_height(VCDecoder *decoder);

int vc_decoder_seek(VCDecoder *decoder, double seconds, int exact, VCDecodedFrame *out_frame);
int vc_decoder_next(VCDecoder *decoder, VCDecodedFrame *out_frame);
void vc_frame_release(VCDecodedFrame *frame);

#ifdef __cplusplus
}
#endif
