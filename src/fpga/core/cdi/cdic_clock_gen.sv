module cdic_clock_gen (
    input clk, input clk_audio, input reset,
    output sector_tick, output sample_tick37, output sample_tick44,
    output mpeg_45tick
);
    pocket_tick #(.RATE(75)) sector (.clk, .reset, .tick(sector_tick));
    pocket_tick #(.RATE(37800)) xa (.clk, .reset, .tick(sample_tick37));
    pocket_tick #(.RATE(44100)) pcm (.clk, .reset, .tick(sample_tick44));
    assign mpeg_45tick = 1'b0;
endmodule
