`include "cdi_types.svh"
module dual_ad7528_attenuation (
    input clk,

    // Connection to SLAVE GPIOs
    input datadac,  // Selects DAC A/B and is data for shift register
    input csdac2n,  // Latches DAC for attenuation of right Audio
    input csdac1n,  // Latches DAC for attenuation of left Audio
    input clkdac,   // Clocks shift register

    // Configuration by MPEG DSP
    input linear_volume_s mpeg_volume,

    input signed [15:0] audio_left_in,
    input signed [15:0] audio_right_in,

    input signed [15:0] mpeg_left_in,
    input signed [15:0] mpeg_right_in,

    output bit signed [15:0] audio_left_out,
    output bit signed [15:0] audio_right_out
);

    enum {
        CDIC_LEFT_A,
        CDIC_LEFT_B,
        MPEG_LEFT_A,
        MPEG_LEFT_B,
        CDIC_RIGHT_A,
        CDIC_RIGHT_B,
        MPEG_RIGHT_A,
        MPEG_RIGHT_B
    } state;

    bit clkdac_q;
    // Implements 7512, a 74HC164
    // Data is shifted in Q0 and continues to Q7
    bit [7:0] shiftreg;
    always_ff @(posedge clk) begin
        clkdac_q <= clkdac;

        if (!clkdac_q && clkdac) begin
            shiftreg <= {shiftreg[6:0], datadac};
        end
    end

    // for both AD7528, the input A is the same side while the input B is the other side
    // 7530 AD7528 produces Audio Right
    //    VrefA is DAC Right
    //    VrefB is DAC Left
    // 7550 AD7528 produces Audio Left
    //    VrefA is DAC Left
    //    VrefB is DAC Right
    bit [7:0] factor_left_a;
    bit [7:0] factor_left_b;
    bit [7:0] factor_right_a;
    bit [7:0] factor_right_b;

    bit csdac1n_q;
    bit csdac2n_q;

    // Limit volume to a certain degree
    // A factor of 9/16 fits by the rule of thumb with the clipping behavior
    // observed on a 210/05. The real machine has two 16 bit channels which are
    // summed together using an analog circuit. This is something
    // we can't do here since our output only has 16 bit.
    // We are losing a little bit of resolution with this...
    wire [7:0] scaled_shiftreg = shiftreg * 9 / 16;

    always_ff @(posedge clk) begin
        csdac1n_q <= csdac1n;
        csdac2n_q <= csdac2n;

        if (!csdac1n && csdac1n_q) begin
            $display("DAC Left %d %d", datadac, shiftreg);
            if (datadac) factor_left_a <= scaled_shiftreg;
            else factor_left_b <= scaled_shiftreg;
        end

        if (!csdac2n && csdac2n_q) begin
            $display("DAC Right %d %d", datadac, shiftreg);
            if (datadac) factor_right_a <= scaled_shiftreg;
            else factor_right_b <= scaled_shiftreg;
        end
    end

    // MAC register
    // To save some ressources, we use only one DSP block for all 4 multiplications here
    // How wide does the Accu need to be? We have 4 sources
    // (VMPEG Left, VMPEG Right, CDIC Left, CDIC Right) and
    // we use 8 bits for fractions. So 16 + 8 + 2 = 26 bits
    bit signed [25:0] temp;
    bit signed [23:8] temp_clipped;

    always_comb begin
        if (signed'(temp[25:8]) > signed'(18'h7fff)) temp_clipped[23:8] = 16'h7fff;
        else if (signed'(temp[25:8]) < signed'(-18'h7fff)) temp_clipped[23:8] = -16'h7fff;
        else temp_clipped[23:8] = temp[23:8];
    end

    bit signed  [15:0] mul_a;  /* 16 bit sample */
    bit signed  [ 8:0] mul_b;  /* 9 bit factor */
    wire signed [25:0] mul_out = mul_a * mul_b;  /* 9 + 16 = 25 bit product */

    always_comb begin
        case (state)
            CDIC_LEFT_A: begin
                mul_a = audio_left_in;
                mul_b = signed'({1'b0, factor_left_a});
            end
            CDIC_LEFT_B: begin
                mul_a = audio_right_in;
                mul_b = signed'({1'b0, factor_left_b});
            end
            CDIC_RIGHT_A: begin
                mul_a = audio_right_in;
                mul_b = signed'({1'b0, factor_right_a});
            end
            CDIC_RIGHT_B: begin
                mul_a = audio_left_in;
                mul_b = signed'({1'b0, factor_right_b});
            end

            MPEG_LEFT_A: begin
                mul_a = mpeg_left_in;
                mul_b = signed'({1'b0, mpeg_volume.factor_l2l});
            end
            MPEG_LEFT_B: begin
                mul_a = mpeg_right_in;
                mul_b = signed'({1'b0, mpeg_volume.factor_r2l});
            end
            MPEG_RIGHT_A: begin
                mul_a = mpeg_left_in;
                mul_b = signed'({1'b0, mpeg_volume.factor_l2r});
            end
            MPEG_RIGHT_B: begin
                mul_a = mpeg_right_in;
                mul_b = signed'({1'b0, mpeg_volume.factor_r2r});
            end
        endcase

    end

    // Left and Right might be swapped here. There is a reason for that:
    // According to an internal memo http://icdia.co.uk/docs/mono2status.zip
    // there was discrepancy between left and right on Mono I and Mono II
    // hardware. This configuration shall establish the order which
    // one would expect from an Audio CD which is also consistent
    // with the panning of Zelda's Adventure
    always_ff @(posedge clk) begin
        case (state)
            CDIC_LEFT_A: begin
                audio_left_out <= temp_clipped[23:8];

                state <= CDIC_LEFT_B;
                temp <= mul_out;
            end
            CDIC_LEFT_B: begin
                state <= MPEG_RIGHT_A;
                temp  <= temp + mul_out;
            end
            MPEG_RIGHT_A: begin
                state <= MPEG_RIGHT_B;
                temp  <= temp + mul_out;
            end
            MPEG_RIGHT_B: begin
                state <= CDIC_RIGHT_A;
                temp  <= temp + mul_out;
            end

            CDIC_RIGHT_A: begin
                audio_right_out <= temp_clipped[23:8];

                state <= CDIC_RIGHT_B;
                temp <= mul_out;
            end
            CDIC_RIGHT_B: begin
                state <= MPEG_LEFT_A;
                temp  <= temp + mul_out;
            end
            MPEG_LEFT_A: begin
                state <= MPEG_LEFT_B;
                temp  <= temp + mul_out;
            end
            MPEG_LEFT_B: begin
                state <= CDIC_LEFT_A;
                temp  <= temp + mul_out;
            end
        endcase
    end

endmodule
