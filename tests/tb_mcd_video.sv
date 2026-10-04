`timescale 1ns/1ps
`include "videotypes.svh"
module tb_mcd_video;
    reg clk=0, reset=1, ce=0;
    always #16.666667 clk=~clk;
    always @(posedge clk) if(reset) ce<=0;else ce<=!ce;
    reg [23:1] cpu_address=0;
    reg [15:0] cpu_din=0;
    reg cpu_uds=0,cpu_lds=0,cpu_write_strobe=0,cs=0;
    wire hs,vs,hblank,vblank,field,interlaced,ready;
    rgb888_s source_rgb;
    wire [24:0] addr;
    wire rd,wr,word_access,burst,refresh;
    wire [15:0] din;
    reg [15:0] dout=0;
    reg busy=0,valid=0;
    mcd212 mcd(.clk,.reset,.cpu_address,.cpu_din,.cpu_uds,.cpu_lds,
        .cpu_write_strobe,.cs,.cpu_dout(),.cpu_bus_ack(),
        .dvc_ram_cs(1'b0),.dvc_rom_cs(1'b0),.vidout(source_rgb),
        .hsync(hs),.vsync(vs),.hblank,.vblank,.vga_f1(field),
        .video_interlaced(interlaced),.video_initialized(ready),.vsd(),
        .sdram_addr(addr),.sdram_rd(rd),.sdram_wr(wr),.sdram_word(word_access),
        .sdram_din(din),.sdram_dout(dout),.sdram_busy(busy),.sdram_burst(burst),
        .sdram_refresh(refresh),.sdram_burstdata_valid(valid),.irq(),
        .debug_force_video_plane(2'b0),.debug_limited_to_full(2'b0),.disable_cpu_starve(1'b0));
    wire [23:0] rgb;
    wire de,skip,vhs,vvs;
    pocket_video adapter(.clk,.reset,.machine_reset(reset),.picture_ready(ready),
        .rgb({source_rgb.r,source_rgb.g,source_rgb.b}),.hblank,.vblank,.hs,.vs,.ce,.interlaced,.field,
        .video_rgb(rgb),.video_de(de),.video_skip(skip),.video_hs(vhs),.video_vs(vvs));
    reg [15:0] mem[524288];
    integer white_pixels=0,green_pixels=0,visible_pixels=0;
    always @(posedge clk) begin
        if(!hblank && !vblank && ce) begin
            if({source_rgb.r,source_rgb.g,source_rgb.b}==24'hFFFFFF) white_pixels++;
            if({source_rgb.r,source_rgb.g,source_rgb.b}==24'h00FF00) green_pixels++;
        end
        if(de && !skip && rgb==24'hFFFFFF) visible_pixels++;
        if(adapter.state==0 && de && !skip && rgb!=0)
            $fatal(1,"MCD startup backdrop leaked through black output");
    end
    reg [18:0] read_address;
    integer remaining=0,delay_count=0;
    always @(posedge clk) begin
        valid<=0;
        if(busy) begin
            if(delay_count!=0) delay_count<=delay_count-1;
            else if(remaining!=0) begin
                dout<=mem[read_address];valid<=1;
                read_address<=read_address+1;remaining<=remaining-1;
            end else busy<=0;
        end else if(rd || wr) begin
            busy<=1;delay_count<=2;
            read_address<=addr[19:1];remaining<=refresh ? 0 : (burst ? 4 : 1);
        end
    end
    task automatic write_register(input [23:0] address,input [15:0] data);
        @(negedge clk);cpu_address=address[23:1];cpu_din=data;
        cs=1;cpu_uds=1;cpu_lds=1;cpu_write_strobe=1;
        @(negedge clk);cs=0;cpu_uds=0;cpu_lds=0;cpu_write_strobe=0;
        repeat(10) @(negedge clk);
    endtask
    always @(posedge vs) begin
        #1;
        $display("MCD frame: DCR1=%h ICM=%h ready=%b qualified=%b width=%d height=%d bad=%b state=%d",
            mcd.command_register_dcr1,mcd.image_coding_method_register,ready,
            adapter.qualified,adapter.frame_width,adapter.lines,adapter.bad_frame,adapter.state);
    end
    initial begin
        foreach(mem[i]) mem[i]=0;
        // A minimal ICA list, fetched through the actual MCD212 arbitrator.
        mem['h200]=16'hC000;mem['h201]=16'h0000; // both image planes off
        mem['h202]=16'hCD01;mem['h203]=16'h4020; // cursor at 32,20
        mem['h204]=16'hCE00;mem['h205]=16'h000F; // initially disabled cursor
        mem['h206]=16'hCF00;mem['h207]=16'hFFFF; // first cursor row
        mem['h208]=16'hD800;mem['h209]=16'h000A; // full green backdrop
        mem['h20A]=16'h0000;mem['h20B]=16'h0000; // stop
        repeat(8) @(negedge clk);reset=0;
        write_register(24'h4ffff2,16'h4200);
        repeat(2) @(posedge vs);#1;
        if(ready || adapter.state!=0 || green_pixels==0)
            $fatal(1,"pure MCD backdrop must remain black during startup");
        $display("PASS actual MCD backdrop remains hidden before cursor or image programming");
        @(negedge clk);mem['h204]=16'hCE80; // independent cursor enable
        repeat(7) @(posedge vs);
        #1;
        if(!ready || adapter.state!=2 || white_pixels==0 || visible_pixels==0 ||
            mcd.command_register_dcr1.de || mcd.image_coding_method_register!=0)
            $fatal(1,"actual MCD212 cursor-only video never became live");
        $display("PASS actual MCD cursor-only picture reaches APF with DCR1.DE clear and image planes off");
        @(negedge clk);mem['h204]=16'hCE00;
        repeat(2) @(posedge vs);#1;
        if(!ready || adapter.state!=2 || mcd.cursor_control_register.en)
            $fatal(1,"backdrop-only scene after startup was hidden again");
        $display("PASS later uniform scenes keep native video live after cursor is disabled");

        // Both plane paths also start video when DE is clear. Reset must
        // clear the latch; the subsequent ICA fetch reinitializes it.
        @(negedge clk);reset=1;
        repeat(8) @(negedge clk);
        if(ready) $fatal(1,"warm reset did not clear display readiness");
        mem['h201]=16'h0001;reset=0;
        write_register(24'h4ffff2,16'h4200);
        repeat(2) @(posedge vs);#1;
        if(!ready || mcd.command_register_dcr1.de || mcd.cursor_control_register.en)
            $fatal(1,"plane A with DE clear did not initialize video");
        $display("PASS actual MCD plane A initializes video with DE clear after warm reset");
        @(negedge clk);reset=1;
        repeat(8) @(negedge clk);
        if(ready) $fatal(1,"second reset did not clear display readiness");
        mem['h201]=16'h0100;reset=0;
        write_register(24'h4fffe2,16'h0200);
        write_register(24'h4ffff2,16'h4200);
        repeat(2) @(posedge vs);#1;
        if(!ready || mcd.image_coding_method_register.cm13_10_planea!=0 ||
            mcd.command_register_dcr1.de || mcd.cursor_control_register.en)
            $fatal(1,"plane B with DE clear did not initialize video");
        $display("PASS actual MCD plane B initializes video with plane A off and DE clear");
        $display("ALL MCD VIDEO TESTS PASSED");$finish;
    end
    initial begin #500000000;$fatal(1,"MCD video timeout");end
endmodule
