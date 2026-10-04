// from https://www.fpga4fun.com/CrossClockDomain1.html

module signal_cross_domain (
    input  clk_a,
    input  signal_in_clk_a,  // this is a one-clock pulse from the clk_a domain
    input  clk_b,
    output signal_out_clk_b  // from which we generate a one-clock pulse in clk_b domain
);

    bit signal_clk_a;
    always_ff @(posedge clk_a) signal_clk_a <= signal_in_clk_a;

    bit [1:0] synca_clk_b;
    always @(posedge clk_b) synca_clk_b[0] <= signal_clk_a;  // notice that we use clkB
    always @(posedge clk_b) synca_clk_b[1] <= synca_clk_b[0];  // notice that we use clkB

    assign signal_out_clk_b = synca_clk_b[1];  // new signal synchronized to (=ready to be used in) clkB domain

endmodule
