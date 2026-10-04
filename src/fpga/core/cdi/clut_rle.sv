`include "videotypes.svh"

module clut_rle (
    input clk,
    input reset,
    input st,
    pixelstream.sink src,
    pixelstream.source dst,
    input file_type_e ft,
    input mosaic_factor_e mf
);
    // If the upper bit is 0, the second is to be ignored
    wire passthrough = !ft[1];

    enum bit [3:0] {
        SINGLE,
        RLE_GET_NUMBER,
        RLE_LIMITED,
        RLE_UNTIL_END_OF_LINE
    } state = SINGLE;

    bit [7:0] rle_counter = 0;
    bit [7:0] stored_pixel = 0;

    /// counts the number of remaining pixels in this line
    bit [8:0] pixelcounter;
    wire reset_pixelcounter = pixelcounter == 0;

    always_ff @(posedge clk) begin
        if (reset || reset_pixelcounter) pixelcounter <= st ? 360 : 384;
        else if (dst.write && dst.strobe) pixelcounter <= pixelcounter - 1;
    end

    always_comb begin
        dst.write  = 0;
        src.strobe = 0;
        dst.pixel  = stored_pixel;

        if (passthrough || reset) begin
            dst.pixel  = src.pixel;
            src.strobe = dst.strobe;
            dst.write  = src.write;
        end else begin
            case (state)
                SINGLE: begin
                    if (src.pixel[7] || ft == kMosaic) begin
                        src.strobe = src.write;
                    end else begin
                        // Just pass through
                        dst.pixel  = {1'b0, src.pixel[6:0]};
                        dst.write  = src.write;
                        src.strobe = dst.strobe;
                    end
                end
                RLE_GET_NUMBER: begin
                    if (src.write) src.strobe = 1;
                end
                RLE_LIMITED: begin
                    if (rle_counter != 0) dst.write = 1;
                end
                RLE_UNTIL_END_OF_LINE: begin
                    if (pixelcounter != 0) dst.write = 1;
                end
                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset || passthrough) begin
            state <= SINGLE;
            rle_counter <= 0;
        end else begin
            case (state)
                SINGLE: begin
                    if (src.write) begin
                        if (ft == kMosaic) begin
                            // Implement Mosaic by using RLE with the duration coming from Mosaic factor
                            stored_pixel <= src.pixel;
                            state <= RLE_LIMITED;
                            rle_counter <= 2 << mf;
                        end else if (src.pixel[7]) begin
                            stored_pixel <= {1'b0, src.pixel[6:0]};
                            state <= RLE_GET_NUMBER;
                        end
                    end
                end
                RLE_GET_NUMBER: begin
                    if (src.write) begin
                        rle_counter <= src.pixel;

                        //$display("RLE %d %d", src.pixel, dst.pixel);
                        if (src.pixel == 0) state <= RLE_UNTIL_END_OF_LINE;
                        else state <= RLE_LIMITED;
                    end
                end
                RLE_LIMITED: begin
                    if (rle_counter == 0) begin
                        state <= SINGLE;
                    end else if (dst.strobe) begin
                        rle_counter <= rle_counter - 1;
                    end
                end
                RLE_UNTIL_END_OF_LINE: begin
                    if (pixelcounter == 0) state <= SINGLE;
                end
                default: begin
                end
            endcase
        end
    end
endmodule



