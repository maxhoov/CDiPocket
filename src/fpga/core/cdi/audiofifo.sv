`timescale 1 ns / 1 ns

module audiofifo (
    input clk,
    input reset,
    audiostream.sink in,
    audiostream.source out,
    output nearly_full,
    output nearly_empty
);

    bit signed [15:0] mem[64];
    bit [5:0] read_index_d;
    bit [5:0] read_index_q;
    bit [5:0] write_index;
    bit [6:0] count;

    // The memory introduces one cycle delay. This is an issue
    // when the FIFO is empty. We want to avoid using the memory readout
    // when reading from a value that is just written
    bit indizes_equal_during_write_d;
    bit indizes_equal_during_write_q;

    assign out.write = count != 0 && !reset && !indizes_equal_during_write_q;
    assign in.strobe = count < 60 && !reset && in.write;

    // Always a minimum of 28 XA samples per block
    // We go for 48 just to be safe
    assign nearly_full = count >= 48;
    assign nearly_empty = count <= 3;

    always_comb begin
        read_index_d = read_index_q;
        if (out.strobe && out.write) begin
            read_index_d = read_index_q + 1;
        end

        indizes_equal_during_write_d = write_index == read_index_d && in.write;
    end

    always_ff @(posedge clk) begin
        if (in.strobe && !out.strobe) count <= count + 1;
        if (!in.strobe && out.strobe && count != 0) count <= count - 1;

        if (reset) begin
            write_index <= 0;
            read_index_q <= 0;
            count <= 0;
        end else begin
            if (in.write && in.strobe) begin
                mem[write_index] <= in.sample;
                write_index <= write_index + 1;
            end

            out.sample <= mem[read_index_d];
            read_index_q <= read_index_d;
            indizes_equal_during_write_q <= indizes_equal_during_write_d;
        end
    end
endmodule
