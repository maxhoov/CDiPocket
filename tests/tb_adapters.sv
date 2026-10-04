`timescale 1ns/1ps
`include "bus.svh"
module tb_adapters;
    reg sys=0,host=0,audio=0,reset=1;
    always #16.666667 sys=~sys;
    always #6.734007 host=~host;
    always #40.690104 audio=~audio;
    wire tick75,tick37,tick44;
    pocket_tick #(.RATE(75)) t0(.clk(sys),.reset,.tick(tick75));
    pocket_tick #(.RATE(37800)) t1(.clk(sys),.reset,.tick(tick37));
    pocket_tick #(.RATE(44100)) t2(.clk(sys),.reset,.tick(tick44));
    wire dac,lrck;
    pocket_audio audio_out(.clk_sys(sys),.clk_audio(audio),.reset,.mute(1'b0),
        .left(16'h1234),.right(16'hdabc),.dac,.lrck);
    reg [12:0] addr_a=0;
    reg [10:0] addr_b=0;
    reg [7:0] data_a=0;
    reg [31:0] data_b=0;
    reg we_a=0,we_b=0;
    wire [7:0] qa;
    wire [31:0] qb;
    pocket_byte_ram nvram(.clk_a(sys),.clk_b(host),.addr_a,.addr_b,.data_a,.data_b,
        .we_a,.we_b,.q_a(qa),.q_b(qb));
    reg [31:0] keys=32'h10000000;
    reg rts=0;
    bytestream serial();
    pocket_controller pad(.clk(sys),.reset,.keys,.rts,.serial_out(serial));
    integer tx_count=0;
    reg [7:0] received[0:7];
    always @(posedge sys) if(serial.write) begin
        received[tx_count]=serial.data;tx_count=tx_count+1;
    end
    initial begin
        #200;@(negedge sys) reset=0;
        // Native BRIDGE word -> sequential CPU byte addresses.
        @(negedge host);we_b=1;data_b=32'h11223344;addr_b=0;
        @(negedge host);we_b=0;
        for(integer i=0;i<4;i=i+1) begin
            @(negedge sys);addr_a=i;
            @(posedge sys);#1;
            if(qa!==(8'h11*(i+1))) $fatal(1,"NVRAM endian lane %d: %h",i,qa);
        end
        @(negedge sys);addr_a=2;data_a=8'haa;we_a=1;
        @(negedge sys);we_a=0;
        repeat(3) @(posedge host);#1;
        if(qb!==32'h1122aa44) $fatal(1,"NVRAM native readback: %h",qb);
        $display("PASS NVRAM restore/CPU-write/backup byte order");
    end
    initial begin
        wait(!reset);
        repeat(4) @(negedge lrck);
        // Decode with the re-created 64*Fs bit clock, one spacer then MSB.
        @(negedge lrck);
        @(posedge audio_out.phase[1]);
        begin
            reg [15:0] sample;
            for(integer i=0;i<16;i=i+1) begin
                @(posedge audio_out.phase[1]);#1;sample={sample[14:0],dac};
            end
            if(sample!==16'h1234) $fatal(1,"I2S left: %h",sample);
            @(posedge lrck);@(posedge audio_out.phase[1]);
            for(integer i=0;i<16;i=i+1) begin
                @(posedge audio_out.phase[1]);#1;sample={sample[14:0],dac};
            end
            if(sample!==16'hdabc) $fatal(1,"I2S right: %h",sample);
        end
        $display("PASS 48 kHz I2S one-bit delay and stereo sample order");
    end
    initial begin
        wait(!reset);keys=32'h10000048; // Right + X -> both CD-i buttons.
        wait(tx_count==4);
        if(received[0]!==8'hca || received[1]!==8'hf0 || received[2]!==8'h88 || received[3]!==8'h80)
            $fatal(1,"Controller protocol %h %h %h %h",received[0],received[1],received[2],received[3]);
        $display("PASS standard controller ID, both-button chord and direction");
    end
    integer n75=0,n37=0,n44=0;
    initial begin
        wait(!reset);
        repeat(3000000) begin
            @(posedge sys);#1;
            if(tick75)n75=n75+1;if(tick37)n37=n37+1;if(tick44)n44=n44+1;
        end
        if(n75!=7 || n37!=3780 || n44!=4410)
            $fatal(1,"tick rates %d %d %d",n75,n37,n44);
        $display("PASS 75 Hz/37.8 kHz/44.1 kHz rational tick rates");
        $display("ALL ADAPTER TESTS PASSED");$finish;
    end
    initial begin #110000000;$fatal(1,"timeout");end
endmodule
