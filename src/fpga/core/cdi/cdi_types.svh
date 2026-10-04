`ifndef CDI_TYPES_SVH
`define CDI_TYPES_SVH
typedef struct packed {
    bit [7:0] factor_r2r;
    bit [7:0] factor_l2r;
    bit [7:0] factor_r2l;
    bit [7:0] factor_l2l;
} linear_volume_s;
`endif
