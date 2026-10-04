`ifndef AUDIO_TYPES_SVH
`define AUDIO_TYPES_SVH

typedef enum bit [1:0] {
    kMono,
    kStereo,
    kChanReserved,
    kChanMpeg
} chan_e;

typedef enum bit [1:0] {
    k37Khz,
    k18Khz,
    kRateReserved,
    k44Khz
} rate_e;

typedef enum bit [1:0] {
    k4Bps,
    k8Bps,
    k16Bps,
    kMpegBps
} bps_e;

typedef struct packed {
    bit eof;
    bit rt;
    bit form;
    bit trig;
    bit data;
    bit audio;
    bit video;
    bit eor;
} header_submode_s;

typedef struct packed {
    bit [1:0] reserved;

    bps_e  bps;
    rate_e rate;
    chan_e chan;

} header_coding_s;

`endif
