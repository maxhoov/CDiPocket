`timescale 1 ns / 1 ns

module videofifo (
    input clk,
    input reset,
    pixelstream.sink in,
    pixelstream.source out
);

    bit [7:0] mem[8];
    bit [2:0] read_index_d;
    bit [2:0] read_index_q;
    bit [2:0] write_index;
    bit [2:0] count;

    // The memory introduces one cycle delay. This is an issue
    // when the FIFO is empty. We want to avoid using the memory readout
    // when reading from a value that is just written
    bit indizes_equal_during_write_d;
    bit indizes_equal_during_write_q;

    assign out.write = count != 0 && !reset && !indizes_equal_during_write_q;
    assign in.strobe = count < 7 && !reset && in.write;

    always_comb begin
        read_index_d = read_index_q;
        if (out.strobe) read_index_d = read_index_q + 1;

        indizes_equal_during_write_d = write_index == read_index_d && in.write;
    end

    always_ff @(posedge clk) begin
        if (in.strobe && !out.strobe) count <= count + 1;
        if (!in.strobe && out.strobe) count <= count - 1;

        if (reset) begin
            write_index <= 0;
            read_index_q <= 0;
            count <= 0;
        end else begin
            if (in.write && in.strobe) begin
                mem[write_index] <= in.pixel;
                write_index <= write_index + 1;
            end

            out.pixel <= mem[read_index_d];
            read_index_q <= read_index_d;
            indizes_equal_during_write_q <= indizes_equal_during_write_d;
        end
    end
endmodule
