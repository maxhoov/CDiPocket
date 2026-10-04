// from https://www.fpga4fun.com/CrossClockDomain2.html

module flag_cross_domain (
    input  clk_a,
    input  flag_in_clk_a,  // this is a one-clock pulse from the clk_a domain
    input  clk_b,
    output flag_out_clk_b  // from which we generate a one-clock pulse in clk_b domain
);

    bit flagtoggle_clk_a;
    always_ff @(posedge clk_a)
        flagtoggle_clk_a <= flagtoggle_clk_a ^ flag_in_clk_a;  // when flag is asserted, this signal toggles (clk_a domain)

    bit [2:0] synca_clk_b;
    always_ff @(posedge clk_b)
        synca_clk_b <= {
            synca_clk_b[1:0], flagtoggle_clk_a
        };  // now we cross the clock domains

    assign flag_out_clk_b = (synca_clk_b[2] ^ synca_clk_b[1]);  // and create the clk_b flag
endmodule
