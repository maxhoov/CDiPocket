`timescale 1ns/1ps
`include "bus.svh"
module tb_pause;
    reg clk=0,host=0,audio=0,reset=1,core_reset=1,in_menu=0,vblank=0;
    always #16.666667 clk=~clk;
    always #6.734007 host=~host;
    always #40.690104 audio=~audio;
    wire machine_clk,paused,mute,ready,idle;
    reg cdi_rd=0,cdi_wr=0,cdi_burst=0;
    wire busy,valid,rd,wr,word,burst,refresh;
    wire [24:0] addr;
    wire [15:0] din,dout;
    pocket_pause pause_control(.clk,.core_reset,.in_menu,.vblank,.memory_idle(idle),
        .memory_busy(busy),.memory_valid(valid),.cdi_rd,.cdi_wr,.clk_machine(machine_clk),.paused,.mute);
    pocket_memory #(.RAM_BYTES(4096)) manager(.clk,.reset,.core_reset,.paused,
        .loader_data(64'b0),.loader_empty(1'b1),.loader_pop(),.accepting(),.ready,.idle,
        .slave_addr(),.slave_data(),.slave_wr(),.cdi_addr(25'h10),.cdi_din(16'hbeef),
        .cdi_rd,.cdi_wr,.cdi_word(1'b1),.cdi_burst,.cdi_refresh(1'b0),
        .addr,.din,.rd,.wr,.word,.burst,.refresh,.busy);
    wire [15:0] dq;
    wire [12:0] a;
    wire [1:0] ba,dqm;
    wire dram_clk,nwe,nras,ncas;
    sdram controller(.clk,.init(reset),.addr,.din,.dout,.rd,.wr,.word,.burst,.refresh,
        .busy,.burstdata_valid(valid),.SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),
        .SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),.SDRAM_nCS(),
        .SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_CLK(dram_clk),.SDRAM_CKE());
    reg drive_enable=0,read_active=0;
    reg [15:0] drive=0;
    integer delay_count=0,burst_index=0,refreshes=0,write_count=0;
    real last_refresh=0;
    assign dq=drive_enable ? drive : 16'hzzzz;
    always @(posedge dram_clk) begin
        if(!paused) last_refresh=0;
        if(read_active) begin
            if(delay_count!=0) delay_count=delay_count-1;
            if(delay_count==0) begin
                drive_enable<=#5 1;drive<=#5 16'h100+burst_index;
                burst_index=burst_index+1;
                if(burst_index==4) read_active=0;
            end
        end else drive_enable<=#5 0;
        case({nras,ncas,nwe})
            3'b101: begin burst_index=0;delay_count=1;read_active=1;end
            3'b100: write_count=write_count+1;
            3'b001: if(paused) begin
                if(last_refresh!=0 && $realtime-last_refresh>8000)
                    $fatal(1,"Paused SDRAM refresh exceeded 8 us");
                last_refresh=$realtime;refreshes=refreshes+1;
            end
        endcase
    end
    integer machine_cycles=0,words=0,acks=0;
    reg busy_seen=0;
    always @(posedge machine_clk) begin
        machine_cycles=machine_cycles+1;
        busy_seen<=busy;
        if(!core_reset && !busy && busy_seen) acks=acks+1;
        if(!core_reset && valid) begin
            if(dout!==16'h100+words) $fatal(1,"Pause lost SDRAM burst word %d: %h",words,dout);
            words=words+1;
        end
    end
    real rising_edge=0;
    always @(posedge machine_clk) begin
        if(clk!==1'b1) $fatal(1,"Machine clock rose outside input clock");
        rising_edge=$realtime;
    end
    always @(negedge machine_clk) if(rising_edge!=0)
        if($realtime-rising_edge<16.66) $fatal(1,"Runt machine clock pulse");
    // A held source pulse must not repeatedly toggle the host event mailbox.
    reg nv_changed=0;
    wire nv_event;
    flag_cross_domain nv_cross(.clk_a(machine_clk),.clk_b(host),
        .flag_in_clk_a(nv_changed),.flag_out_clk_b(nv_event));
    integer nv_events=0;
    always @(posedge host) if(nv_event) nv_events=nv_events+1;
    bytestream pad_serial();
    pocket_controller pad(.clk(machine_clk),.reset(core_reset),.keys(32'h10000008),
        .rts(1'b0),.serial_out(pad_serial));
    wire dac,lrck;
    pocket_audio sound(.clk_sys(clk),.clk_audio(audio),.reset(core_reset),.mute,
        .left(16'h1234),.right(16'hdabc),.dac,.lrck);
    task automatic check_audio(input [15:0] left,input [15:0] right);
        reg [15:0] sample;
        repeat(3) @(negedge lrck);
        @(posedge sound.phase[1]);
        for(integer i=0;i<16;i=i+1) begin
            @(posedge sound.phase[1]);#1;sample={sample[14:0],dac};
        end
        if(sample!==left) $fatal(1,"Pause I2S left %h expected %h",sample,left);
        @(posedge lrck);@(posedge sound.phase[1]);
        for(integer i=0;i<16;i=i+1) begin
            @(posedge sound.phase[1]);#1;sample={sample[14:0],dac};
        end
        if(sample!==right) $fatal(1,"Pause I2S right %h expected %h",sample,right);
    endtask
    initial begin
        integer snapshot,pad_timer,old_writes,old_acks;
        #200;@(negedge clk);reset=0;
        wait(ready);@(negedge clk);core_reset=0;
        check_audio(16'h1234,16'hdabc);
        @(negedge clk);in_menu=1;
        snapshot=machine_cycles;
        repeat(40) @(posedge clk);#1;
        if(paused || machine_cycles==snapshot) $fatal(1,"Paused outside vertical blank");
        // Menu is pending while an actual SDRAM burst is being completed.
        @(negedge clk);cdi_burst=1;cdi_rd=1;vblank=1;
        wait(busy);@(negedge clk);cdi_rd=0;
        wait(paused);#1;
        if(words!=4 || acks!=1) $fatal(1,"Stopped before consuming burst/ACK: %d/%d",words,acks);
        snapshot=machine_cycles;pad_timer=pad.timer;old_writes=write_count;old_acks=acks;
        nv_changed=1;
        check_audio(0,0);
        repeat(30000) @(posedge clk);#1;
        if(machine_cycles!=snapshot || pad.timer!=pad_timer || words!=4 || acks!=old_acks)
            $fatal(1,"Machine/controller/SDRAM consumer advanced during pause");
        if(write_count!=old_writes || refreshes<100 || nv_events!=0)
            $fatal(1,"Paused service corruption writes=%d refreshes=%d NV events=%d",write_count-old_writes,refreshes,nv_events);
        $display("PASS pause drains all burst words and ACK, freezes state and controller, keeps SDRAM refresh");
        $display("PASS I2S continues at 48 kHz with silent stereo frames during pause");
        // Resume requested during a refresh must wait for that refresh to drain.
        wait(busy);@(negedge clk);in_menu=0;nv_changed=0;
        wait(!paused);#1;
        if(busy || valid) $fatal(1,"Resumed inside a background refresh");
        repeat(20) @(posedge clk);#1;
        if(machine_cycles==snapshot || acks!=old_acks) $fatal(1,"Resume lost state or fabricated an ACK");
        check_audio(16'h1234,16'hdabc);
        $display("PASS resume drains background refresh, preserves state and restores stereo audio");
        // Repeated menus and reset while paused are serviced by ungated logic.
        repeat(5) begin
            @(negedge clk);in_menu=1;wait(paused);snapshot=machine_cycles;
            repeat(25) @(posedge clk);#1;
            if(machine_cycles!=snapshot) $fatal(1,"Repeated menu failed");
            @(negedge clk);in_menu=0;wait(!paused);
            repeat(20) @(posedge clk);
        end
        @(negedge clk);in_menu=1;wait(paused);
        @(negedge clk);core_reset=1;wait(!paused);
        repeat(10) @(posedge machine_clk);#1;
        if(pad.timer!=249999 || paused) $fatal(1,"Reset while paused was blocked");
        $display("PASS repeated menus, reset override and glitch-free dedicated clock enable");
        $display("ALL PAUSE TESTS PASSED");$finish;
    end
    initial begin #5000000;$fatal(1,"Pause timeout paused=%b busy=%b words=%d",paused,busy,words);end
endmodule
