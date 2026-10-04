`timescale 1ns/1ps
module tb_video;
    reg clk=0,reset=1,st=0,fd=0,sm=0,ce=0;
    reg in_menu=0;
    reg adapter_reset=1,picture_ready=0,bad_width=0;
    reg [23:0] source_rgb=24'h123456;
    wire machine_clk,paused;
    always #16.666667 clk=~clk;
    always @(posedge machine_clk) if(reset) ce<=0;else ce<=!ce;
    wire hs,vs,hblank,vblank,parity,fake_parity,new_line;
    wire [8:0] y;
    wire [12:0] x;
    pocket_pause pause_control(.clk,.core_reset(reset),.in_menu,.vblank,
        .memory_idle(1'b1),.memory_busy(1'b0),.memory_valid(1'b0),.cdi_rd(1'b0),.cdi_wr(1'b0),
        .clk_machine(machine_clk),.paused,.mute());
    video_timing timing(.clk(machine_clk),.reset,.fake_parity,.parity,.sm,.cf(1'b1),.st,.cm(1'b0),.fd,
        .video_y(y),.video_x(x),.hsync(hs),.vsync(vs),.hblank,.vblank,.new_line);
    wire [23:0] rgb;
    wire de,skip,vhs,vvs;
    wire source_hblank=hblank || (bad_width && x<384);
    pocket_video adapter(.clk,.reset(adapter_reset),.machine_reset(reset),.picture_ready,
        .rgb(source_rgb),.hblank(source_hblank),.vblank,.hs,.vs,.ce,
        .interlaced(sm),.field(sm && parity),.video_rgb(rgb),
        .video_de(de),.video_skip(skip),.video_hs(vhs),.video_vs(vvs));
    task automatic check_mode(input bit standard,input bit duration,input bit interlace,
        input integer expected_width,input integer expected_lines);
        integer width_count,line_count,vs_age,cycles;
        reg previous_de,previous_hs,previous_vs;
        @(negedge clk);reset=1;picture_ready=0;st=standard;fd=duration;sm=interlace;
        repeat(8) @(negedge clk);reset=0;picture_ready=1;
        wait(adapter.state==2);
        @(negedge vvs);
        width_count=0;line_count=0;vs_age=0;cycles=0;
        previous_de=0;previous_hs=0;previous_vs=0;
        forever begin
            @(posedge clk);#1;cycles=cycles+1;vs_age=vs_age+1;
            if(vvs) begin
                if(previous_vs) $fatal(1,"VS longer than one clock");
                if(line_count!=expected_lines) $fatal(1,"active height got %d expected %d",line_count,expected_lines);
                if(rgb[1]!==interlace || rgb[23:4]!=0) $fatal(1,"APF field metadata %h",rgb);
                break;
            end
            if(vhs && (previous_hs || vs_age<3)) $fatal(1,"HS pulse width or VS gap");
            if(skip && !de) $fatal(1,"SKIP outside DE");
            if(de && !skip) begin
                width_count=width_count+1;
                if(rgb!==24'h123456) $fatal(1,"active RGB corrupted");
            end
            if(previous_de && !de) begin
                if(width_count!=expected_width) $fatal(1,"width got %d expected %d",width_count,expected_width);
                line_count=line_count+1;width_count=0;
            end
            previous_de=de;previous_hs=vhs;previous_vs=vvs;
        end
        $display("PASS APF video %0dx%0d, interlaced=%0d, one-cycle sync/DE/SKIP/metadata",expected_width,expected_lines,interlace);
    endtask
    task automatic check_black_frame;
        integer pixels,lines,cycles,vs_age;
        reg previous_de,previous_hs;
        if(!vvs) @(posedge vvs);
        @(negedge vvs);
        pixels=0;lines=0;cycles=0;vs_age=0;previous_de=0;previous_hs=0;
        forever begin
            @(posedge clk);#1;cycles++;vs_age++;
            if(vvs) begin
                if(lines!=280 || cycles<590000 || cycles>610000 || rgb!=0 || de || skip)
                    $fatal(1,"incomplete black frame: height %d, clocks %d, RGB %h",lines,cycles,rgb);
                break;
            end
            if(vhs && (previous_hs || vs_age<3)) $fatal(1,"black HS pulse or VS gap");
            if(skip && !de) $fatal(1,"black SKIP outside DE");
            if(de && !skip) begin
                pixels++;
                if(rgb!=0) $fatal(1,"loading exposed RGB %h",rgb);
            end
            if(previous_de && !de) begin
                if(pixels!=768) $fatal(1,"black line width %d",pixels);
                pixels=0;lines++;
            end
            previous_de=de;previous_hs=vhs;
        end
    endtask
    always @(posedge clk) begin
        #1;
        if((reset || !picture_ready) && de && !skip && rgb!=0)
            $fatal(1,"reset or loading exposed previous RGB %h",rgb);
    end
    initial begin
        repeat(8) @(negedge clk);adapter_reset=0;
        // A long asset load leaves the machine reset, with stale source RGB.
        repeat(2) check_black_frame();
        $display("PASS complete continuous black frames while machine held in reset");
        @(negedge clk);reset=0;source_rgb=24'h00ffff;
        repeat(2) check_black_frame();
        $display("PASS BIOS backdrop colors suppressed before display initialization");
        @(negedge clk);picture_ready=1;bad_width=1;
        repeat(2) check_black_frame();
        if(adapter.state!=0) $fatal(1,"accepted incomplete native frame");
        $display("PASS malformed native geometry keeps complete black frames");
        @(negedge clk);bad_width=0;source_rgb=24'h123456;
        wait(adapter.state==2);#1;
        if(!vvs || de || skip || rgb[23:4]!=0) $fatal(1,"native handover lost first VS or metadata");
        $display("PASS native video begins at VS after matching complete frames");
        check_mode(0,0,0,768,280);
        @(negedge vblank);@(negedge clk);in_menu=1;
        wait(paused);
        begin
            reg [21:0] position;
            position={y,x};
            repeat(1000) begin
                @(posedge clk);#1;
                if({y,x}!==position || de || skip) $fatal(1,"Paused video advanced or emitted active pixels");
            end
            @(negedge clk);in_menu=0;wait(!paused);
            repeat(100) @(posedge clk);#1;
            if({y,x}===position) $fatal(1,"Video did not resume");
            @(posedge vvs);@(negedge vvs);
        end
        $display("PASS menu freezes video in vertical blank and resumes timing without reset");
        check_mode(1,0,0,720,240);
        check_mode(0,1,0,768,240);
        check_mode(0,0,1,768,280);
        $display("ALL VIDEO TESTS PASSED");$finish;
    end
    initial begin #1500000000;$fatal(1,"video timeout");end
endmodule
