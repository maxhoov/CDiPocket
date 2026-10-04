`include "bus.svh"
`include "videotypes.svh"


module delta_yuv_decoder (
    input clk,
    input reset,
    input st,
    pixelstream src,
    input yuv_s absolute_start_yuv,
    output rgb888_s rgb_out,
    output bit write,
    input strobe
);

    bit signed [9:0] r;
    bit signed [9:0] g;
    bit signed [9:0] b;

    enum bit [3:0] {
        IDLE,
        STATE_UY,
        STATE_VY
    } state = IDLE;

    // Dequantizer Table according to Table 7-1
    localparam bit [7:0] dyuv_deltas[16] = '{
        0,
        1,
        4,
        9,
        16,
        27,
        44,
        79,
        128,
        177,
        212,
        229,
        240,
        247,
        252,
        255
    };

    yuv_s current_color;

    function [7:0] clamp8(input signed [9:0] val);
        if (val > 255) clamp8 = 255;
        else if (val < 0) clamp8 = 0;
        else clamp8 = val[7:0];
    endfunction

    function [7:0] clamp_int8(input int val);
        if (val > 255) clamp_int8 = 255;
        else if (val < 0) clamp_int8 = 0;
        else clamp_int8 = val[7:0];
    endfunction

    always_comb begin
        bit signed [9:0] y, u, v;

        y = {2'b00, current_color.y};
        u = {2'b00, current_color.u};
        v = {2'b00, current_color.v};

        // According to chapter 7.1 DELTA YUV DECODER
        r = (y * 256 + 351 * (v - 128)) / 256;
        g = (y * 256 - 86 * (u - 128) - 179 * (v - 128)) / 256;
        b = (y * 256 + 444 * (u - 128)) / 256;

        rgb_out.r = clamp8(r);
        rgb_out.g = clamp8(g);
        rgb_out.b = clamp8(b);
    end

`ifdef VERILATOR
    // Compare 32 bit int against shorter signed registers
    // to validate resultse
    rgb888_s verify_rgb;
    always_comb begin
        int y, u, v;
        int r, g, b;

        y = int'({2'b00, current_color.y});
        u = int'({2'b00, current_color.u});
        v = int'({2'b00, current_color.v});

        // According to chapter 7.1 DELTA YUV DECODER
        r = (y * 256 + 351 * (v - 128)) / 256;
        g = (y * 256 - 86 * (u - 128) - 179 * (v - 128)) / 256;
        b = (y * 256 + 444 * (u - 128)) / 256;
        verify_rgb.r = clamp_int8(r);
        verify_rgb.g = clamp_int8(g);
        verify_rgb.b = clamp_int8(b);
    end

    always_ff @(posedge clk) begin
        assert (verify_rgb == rgb_out);
    end
`endif

    // According to chapter 7.1 DELTA YUV DECODER
    // Pixel Format is
    // Delta U0 Delta Y0
    // Delta V0 Delta Y1
    // Delta U2 Delta Y2
    // Delta V2 Delta Y3
    // Y is available for every pixel
    // UV is only updated every other pixel
    // UV is interpolated between those pixels

    always_comb begin
        src.strobe = 0;
        if (src.write && !write) begin
            if (state == STATE_UY || state == STATE_VY) src.strobe = 1;
        end
    end

    // T0 is always refreshed with the newest data
    yuv_s t0;
    // T1 and T2 are the previous values.
    // With a combination of all 3, the correct data
    // can be reassembled
    yuv_s t1;
    yuv_s t2;

    bit [1:0] delayed_write;

    always_ff @(posedge clk) begin
        if (strobe) write <= 0;

        if (reset) begin
            state <= IDLE;
            write <= 0;
            delayed_write <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (src.write) begin
                        //When the first data arrives we can be sure that ICA/DCA has
                        // updated the Absolute Start YUV
                        current_color <= absolute_start_yuv;
                        t0 <= absolute_start_yuv;
                        t1 <= absolute_start_yuv;
                        t2 <= absolute_start_yuv;

                        delayed_write <= 0;
                        state <= STATE_UY;
                    end
                end
                STATE_UY: begin
                    if ((src.write || delayed_write != 0) && !write) begin
                        // First byte contains U0 and Y0
                        t0.y <= t0.y + dyuv_deltas[src.pixel[3:0]];
                        t1.y <= t0.y;
                        t2.y <= t1.y;

                        t0.u <= t0.u + dyuv_deltas[src.pixel[7:4]];
                        t1.u <= t0.u;
                        t2.u <= t1.u;

                        current_color.y <= t2.y;
                        current_color.u <= t1.u;
                        current_color.v <= t1.v;

                        {write, delayed_write} <= {delayed_write, 1'b1};
                        state <= STATE_VY;
                    end
                end
                STATE_VY: begin
                    if ((src.write || delayed_write != 0) && !write) begin
                        // Second byte contains V0 and Y1
                        t0.y <= t0.y + dyuv_deltas[src.pixel[3:0]];
                        t1.y <= t0.y;
                        t2.y <= t1.y;

                        t0.v <= t0.v + dyuv_deltas[src.pixel[7:4]];
                        t1.v <= t0.v;
                        t2.v <= t1.v;

                        // Y is always defined
                        current_color.y <= t2.y;
                        // perform interpolation
                        current_color.u <= 8'(({1'b0, t2.u} + {1'b0, t1.u}) >> 1);
                        current_color.v <= 8'(({1'b0, t0.v} + {1'b0, t1.v}) >> 1);

                        {write, delayed_write} <= {delayed_write, 1'b1};
                        state <= STATE_UY;
                    end
                end

                default: begin
                end
            endcase

        end
    end

endmodule
