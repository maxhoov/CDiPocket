// Platform adapters for the base CD-i. Copyright 2026 CDiPocket contributors.
// The APF SPI adapter replies with the previous requested word before issuing
// the next read strobe. Preserve that word across address and bank changes.
module pocket_bridge_reply (
    input clk,input rd,input [31:0] addr,
    input [31:0] command_data,nvram_data,disc_data,register_data,
    output reg [31:0] q=0
);
    reg pending=0;
    reg [7:0] bank=0;
    reg [31:0] register_latch=0;
    always @(posedge clk) begin
        pending<=rd;
        if(rd) begin bank<=addr[31:24];register_latch<=register_data;end
        // Command registers update on the read strobe, so capture one clock
        // later. All responses then use the same transport pipeline.
        if(pending) case(bank)
            8'hf8: q<=command_data;
            8'h40: q<=nvram_data;
            8'h60: q<=disc_data;
            8'h50: q<=register_latch;
            default: q<=0;
        endcase
    end
endmodule

module pocket_boot_status (
    input pll_locked,input memory_accepting,input setup_done,
    input reset_n,input loading,output boot_done,output running
);
    // Clearing 1 MiB takes over 100 ms. It belongs to Setup, while the
    // framework's short Request Status boot poll only waits for usable I/O.
    assign boot_done=pll_locked && memory_accepting;
    assign running=reset_n && setup_done && !loading;
endmodule

// Host 0082 permission is requested at boot even for deferload assets.
// Acceptance of CUE/BIN metadata does not start an automatic file transfer.
module pocket_slot_policy (
    input memory_accepting,input nv_allowed,
    input [15:0] read_id,write_id,input [31:0] write_size,
    output read_ack,read_ok,write_ack,write_ok
);
    assign read_ack=read_id!=3 || !nv_allowed;
    assign read_ok=read_id==3;
    assign write_ack=memory_accepting && (write_id!=3 || !nv_allowed);
    assign write_ok=(write_id==0 && write_size<=32768) ||
        (write_id==1 && write_size==524288) ||
        (write_id==2 && write_size==8192) ||
        (write_id==3 && write_size==8192) ||
        (write_id==4 && write_size<=32'h40000000);
endmodule

module pocket_sync #(parameter WIDTH=1) (
    input clk, input [WIDTH-1:0] d, output [WIDTH-1:0] q
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [WIDTH-1:0] a='0, b='0, c='0;
    always @(posedge clk) begin a<=d; b<=a; c<=b; end
    assign q=c;
endmodule

module pocket_reset(input clk, input release_n, output reset);
    reg [2:0] pipe=0;
    always @(posedge clk or negedge release_n)
        if (!release_n) pipe<=0;
        else pipe<={pipe[1:0],1'b1};
    assign reset=!pipe[2];
endmodule

// Bresenham clock enable: exactly RATE pulses per 30,000,000 clocks.
module pocket_tick #(parameter RATE=75) (input clk, input reset, output reg tick=0);
    reg [24:0] phase=0;
    wire [25:0] next_phase={1'b0,phase}+RATE;
    always @(posedge clk) begin
        tick<=0;
        if (reset) phase<=0;
        else if (next_phase>=30000000) begin
            phase<=next_phase-30000000;
            tick<=1;
        end else phase<=next_phase[24:0];
    end
endmodule

// Mixed-width true dual-port M10Ks. Port A is the emulated
// byte-wide CPU; port B is a native big-endian BRIDGE word.
module pocket_byte_ram (
    input clk_a, input clk_b, input [12:0] addr_a, input [10:0] addr_b,
    input [7:0] data_a, input [31:0] data_b, input we_a, input we_b,
    output reg [7:0] q_a, output [31:0] q_b
);
    wire [7:0] cpu_q;
    wire [31:0] bridge_q;
    wire [31:0] bridge_d={data_b[7:0],data_b[15:8],data_b[23:16],data_b[31:24]};
    altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),
        .intended_device_family("Cyclone V"), .width_a(8), .widthad_a(13),
        .numwords_a(8192), .width_b(32), .widthad_b(11), .numwords_b(2048),
        .address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"),
        .wrcontrol_wraddress_reg_b("CLOCK1"), .outdata_reg_a("UNREGISTERED"),
        .outdata_reg_b("UNREGISTERED"), .read_during_write_mode_mixed_ports("DONT_CARE"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .power_up_uninitialized("FALSE"), .lpm_type("altsyncram")) ram (
        .clock0(clk_a),.clock1(clk_b),.address_a(addr_a),.address_b(addr_b),
        .data_a(data_a),.data_b(bridge_d),.wren_a(we_a),.wren_b(we_b),
        .q_a(cpu_q),.q_b(bridge_q),.rden_a(1'b1),.rden_b(1'b1),
        .byteena_a(1'b1),.byteena_b(1'b1),.aclr0(1'b0),.aclr1(1'b0),
        .addressstall_a(1'b0),.addressstall_b(1'b0),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus()
    );
    always @* q_a=cpu_q;
    assign q_b={bridge_q[7:0],bridge_q[15:8],bridge_q[23:16],bridge_q[31:24]};
endmodule

// Altera's dual-clock FIFO provides Gray-pointer CDC and bounded storage.
module pocket_loader_fifo (
    input wrclk, input rdclk, input reset, input wr, input rd,
    input [63:0] data, output [63:0] q, output full, output empty
);
    dcfifo #(.lpm_width(64), .lpm_numwords(1024), .lpm_widthu(10),
        .lpm_showahead("ON"), .overflow_checking("ON"),
        .underflow_checking("ON"), .use_eab("ON"),
        .read_aclr_synch("ON"), .write_aclr_synch("ON"),
        .rdsync_delaypipe(4), .wrsync_delaypipe(4),
        .intended_device_family("Cyclone V")) fifo (
        .wrclk(wrclk), .rdclk(rdclk), .aclr(reset),
        .wrreq(wr), .rdreq(rd), .data(data), .q(q),
        .wrfull(full), .rdempty(empty), .rdfull(), .wrempty(),
        .rdusedw(), .wrusedw()
    );
endmodule

module pocket_pll(input refclk, output clk30, output clk30_90,
    output audio_clk, output locked);
    wire [1:0] system_clks;
    wire [0:0] audio_clks;
    wire lock_sys,lock_audio;
    altera_pll #(.fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"), .operation_mode("normal"),
        .number_of_clocks(2), .output_clock_frequency0("30 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("30 MHz"), .phase_shift1("8333 ps"),
        .duty_cycle1(50), .pll_type("General"), .pll_subtype("General")) sys (
        .refclk(refclk), .rst(1'b0), .outclk(system_clks), .locked(lock_sys),
        .fbclk(1'b0), .fboutclk()
    );
    altera_pll #(.fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"), .operation_mode("normal"),
        .number_of_clocks(1), .output_clock_frequency0("12.288 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .pll_type("General"), .pll_subtype("General")) audio (
        .refclk(refclk), .rst(1'b0), .outclk(audio_clks), .locked(lock_audio),
        .fbclk(1'b0), .fboutclk()
    );
    assign clk30=system_clks[0];
    assign clk30_90=system_clks[1];
    assign audio_clk=audio_clks[0];
    assign locked=lock_sys && lock_audio;
endmodule

// 48 kHz, 64-bit I2S frames, one bit delay after LRCK. The coherent
// mailbox samples the CDIC output; first version uses zero-order hold.
module pocket_audio (
    input clk_sys, input clk_audio, input reset, input mute,
    input [15:0] left, input [15:0] right,
    output reg dac=0, output reg lrck=0
);
    reg [7:0] phase=0;
    reg request=0, ack=0;
    wire request_sys,ack_audio,mute_audio;
    reg [31:0] mailbox=0, pending=0, frame=0;
    pocket_sync rq (.clk(clk_sys),.d(request),.q(request_sys));
    pocket_sync ak (.clk(clk_audio),.d(ack),.q(ack_audio));
    pocket_sync mu (.clk(clk_audio),.d(mute),.q(mute_audio));
    always @(posedge clk_sys) begin
        if(reset) begin ack<=request_sys; mailbox<=0; end
        else if(request_sys!=ack) begin mailbox<={left,right}; ack<=request_sys; end
    end
    reg seen=0;
    always @(negedge clk_audio) begin
        if(reset) begin phase<=0; dac<=0; lrck<=0; frame<=0;
            pending<=0; request<=0; seen<=ack_audio;
        end else begin
            phase<=phase+1'b1;
            lrck<=phase[7];
            if(ack_audio!=seen) begin pending<=mailbox; seen<=ack_audio; end
            if(phase==0) begin frame<=mute_audio ? 32'b0 : pending; request<=!request; end
            if(phase[1:0]==0) begin
                if(phase[6:2]>=1 && phase[6:2]<=16)
                    dac<=phase[7] ? frame[16-phase[6:2]] : frame[32-phase[6:2]];
                else dac<=0;
            end
        end
    end
endmodule

// Freeze the complete emulated machine at a blanked, quiescent bus boundary.
// The APF bridge, file helper, SDRAM controller and I2S output keep running.
// Both data-valid and the busy falling-edge acknowledgement must have been
// consumed before stopping. Resume also drains any background refresh first.
module pocket_pause (
    input clk, input core_reset, input in_menu, input vblank,
    input memory_idle, input memory_busy, input memory_valid,
    input cdi_rd, input cdi_wr,
    output clk_machine, output reg paused=0, output mute
);
    wire menu_sys;
    reg busy_q=0,valid_q=0;
    pocket_sync menu_sync(.clk(clk),.d(in_menu),.q(menu_sys));
    always @(posedge clk) begin busy_q<=memory_busy;valid_q<=memory_valid;end
    wire quiet=memory_idle && !(memory_busy || busy_q || memory_valid || valid_q);
    wire stop_clock=!core_reset &&
        (paused ? (menu_sys || !quiet) : (menu_sys && vblank && quiet && !cdi_rd && !cdi_wr));
    // Track the same falling-edge decision in an explicit register. The
    // primitive's enaout is an enable feedthrough, not a state register;
    // using it for the sticky pause state creates a combinational loop.
    always @(negedge clk) paused<=stop_clock;
    // Dedicated Cyclone V clock network enable, registered on the falling
    // edge. No combinational LUT or asynchronous menu signal gates the clock.
    cyclonev_clkena #(.clock_type("Global Clock"),.ena_register_mode("falling edge"),
        .ena_register_power_up("high")) machine_clock (
        .inclk(clk),.ena(!stop_clock),.enaout(),.outclk(clk_machine));
    assign mute=menu_sys || paused;
endmodule

// Philips maneuvering controller protocol, 1200 baud (120 bytes/s).
// A=button 1, B=button 2, X=both; no mouse or input overclock.
module pocket_controller(input clk, input reset, input [31:0] keys,
    input rts, bytestream.source serial_out);
    reg [18:0] timer=250000;
    reg [2:0] state=0;
    reg [7:0] packet[3];
    reg [1:0] previous=0;
    wire enabled=keys[31:28]>=1 && keys[31:28]<=3;
    wire [1:0] buttons=enabled ? {keys[4]|keys[6],keys[5]|keys[6]} : 2'b00;
    wire signed [7:0] x=enabled ? (keys[3] ? 8'sd8 : keys[2] ? -8'sd8 : 8'sd0) : 8'sd0;
    wire signed [7:0] y=enabled ? (keys[1] ? 8'sd8 : keys[0] ? -8'sd8 : 8'sd0) : 8'sd0;
    always @(posedge clk) begin
        serial_out.write<=0;
        if(reset || rts) begin state<=0; timer<=249999; previous<=0; end
        else if(timer!=0) timer<=timer-1'b1;
        else begin
            timer<=249999;
            case(state)
                0: begin serial_out.data<=8'hca; serial_out.write<=1; state<=1; end
                1: if(buttons!=previous || x!=0 || y!=0) begin
                    packet[0]<={2'b11,buttons,y[7:6],x[7:6]};
                    packet[1]<={2'b10,x[5:0]}; packet[2]<={2'b10,y[5:0]};
                    previous<=buttons; state<=2;
                end
                2,3,4: begin serial_out.data<=packet[state-2]; serial_out.write<=1;
                    state<=state==4 ? 1 : state+1'b1;
                end
                default: state<=0;
            endcase
        end
    end
endmodule

// Keep supplying real black frames while files load or the BIOS sets up video.
// Both sources share the ungated output clock. No pixel-clock mux is needed.
module pocket_video (
    input clk, input reset, input machine_reset, input picture_ready,
    input [23:0] rgb, input hblank, input vblank,
    input hs, input vs, input ce, input interlaced, input field,
    output reg [23:0] video_rgb=0, output reg video_de=0,
    output reg video_skip=0, output reg video_hs=0, output reg video_vs=0
);
    wire black_hs,black_vs,black_hblank,black_vblank;
    reg black_ce=0;
    always @(posedge clk) if(reset) black_ce<=0;else black_ce<=!black_ce;
    // Fixed 768x280 progressive PAL is already a declared scaler mode.
    // It continues even when the machine clock is paused or held in reset.
    video_timing black_timing(.clk,.reset,.sm(1'b0),.cf(1'b1),.st(1'b0),
        .cm(1'b0),.fd(1'b0),.hsync(black_hs),.vsync(black_vs),
        .hblank(black_hblank),.vblank(black_vblank),
        .fake_parity(),.parity(),.video_y(),.video_x(),.new_line());
    wire [23:0] black_rgb,native_rgb;
    wire black_de,black_skip,black_apf_hs,black_apf_vs;
    wire native_de,native_skip,native_hs,native_vs;
    pocket_video_bus black_bus(.clk,.reset,.rgb(24'b0),.hblank(black_hblank),
        .vblank(black_vblank),.hs(black_hs),.vs(black_vs),.ce(black_ce),
        .interlaced(1'b0),.field(1'b0),.video_rgb(black_rgb),.video_de(black_de),
        .video_skip(black_skip),.video_hs(black_apf_hs),.video_vs(black_apf_vs));
    pocket_video_bus native_bus(.clk,.reset(reset || machine_reset),.rgb,
        .hblank,.vblank,.hs,.vs,.ce,.interlaced,.field,.video_rgb(native_rgb),
        .video_de(native_de),.video_skip(native_skip),.video_hs(native_hs),.video_vs(native_vs));

    reg native_de_q=0,frame_started=0,bad_frame=0,qualified=0;
    reg [10:0] pixels=0,frame_width=0,previous_width=0;
    reg [9:0] lines=0,previous_height=0;
    reg frame_interlaced=0,previous_interlaced=0,previous_good=0;
    wire good_frame=frame_started && !bad_frame &&
        (frame_width==720 || frame_width==768) && (lines==240 || lines==280);
    // Observe two complete, matching frames after display programming. A
    // partial frame or a PAL/NTSC change restarts qualification.
    always @(posedge clk) begin
        native_de_q<=native_de;
        if(native_de && !native_skip) pixels<=pixels+1'b1;
        if(native_de_q && !native_de) begin
            if((pixels!=720 && pixels!=768) || (lines!=0 && pixels!=frame_width)) begin
                bad_frame<=1;qualified<=0;
            end
            frame_width<=pixels;pixels<=0;lines<=lines+1'b1;
        end
        if(interlaced!=frame_interlaced) begin bad_frame<=1;qualified<=0;end
        if(native_vs) begin
            qualified<=good_frame && previous_good && frame_width==previous_width &&
                lines==previous_height && frame_interlaced==previous_interlaced &&
                interlaced==frame_interlaced;
            previous_good<=good_frame;
            previous_width<=frame_width;previous_height<=lines;
            previous_interlaced<=frame_interlaced;
            frame_started<=1;bad_frame<=0;pixels<=0;lines<=0;
            frame_interlaced<=interlaced;
        end
        if(reset || machine_reset || !picture_ready) begin
            native_de_q<=0;frame_started<=0;bad_frame<=0;qualified<=0;
            pixels<=0;lines<=0;frame_width<=0;previous_good<=0;
            previous_width<=0;previous_height<=0;
            frame_interlaced<=interlaced;previous_interlaced<=interlaced;
        end
    end

    localparam BLACK=0,WAIT_NATIVE=1,LIVE=2;
    reg [1:0] state=BLACK;
    wire start_live=state==WAIT_NATIVE && qualified && native_vs && !machine_reset && picture_ready;
    always @(posedge clk) begin
        // Registered selection preserves the very first native VS pulse and
        // all metadata. Once live, menu pause holds the last complete frame.
        video_rgb<=black_rgb;video_de<=black_de;video_skip<=black_skip;
        video_hs<=black_apf_hs;video_vs<=black_apf_vs;
        if(state==WAIT_NATIVE) begin video_de<=0;video_skip<=0;end
        if((state==LIVE || start_live) && !machine_reset && picture_ready) begin
            video_rgb<=native_rgb;video_de<=native_de;video_skip<=native_skip;
            video_hs<=native_hs;video_vs<=native_vs;
        end
        if(state==BLACK && qualified && black_apf_vs) state<=WAIT_NATIVE;
        if(start_live) state<=LIVE;
        if(machine_reset || !picture_ready) state<=BLACK;
        if(reset) begin
            state<=BLACK;video_rgb<=0;video_de<=0;video_skip<=0;video_hs<=0;video_vs<=0;
        end
    end
endmodule

module pocket_video_bus (
    input clk, input reset, input [23:0] rgb, input hblank, input vblank,
    input hs, input vs, input ce, input interlaced, input field,
    output reg [23:0] video_rgb=0, output reg video_de=0,
    output reg video_skip=0, output reg video_hs=0, output reg video_vs=0
);
    reg hs_q=0,vs_q=0,de_q=0;
    reg [2:0] vs_gap=0;
    reg line_pending=0;
    reg [10:0] pixels=0,width=768;
    reg [9:0] lines=0,height=280;
    wire de=!hblank && !vblank;
    wire [2:0] mode={interlaced, height<=240, width<=720};
    always @(posedge clk) begin
        hs_q<=hs; vs_q<=vs; de_q<=de;
        video_hs<=0; video_vs<=0; video_de<=de; video_skip<=de && !ce;
        video_rgb<=de ? rgb : (24'(mode)<<13);
        if(reset) begin video_rgb<=0; video_de<=0; video_skip<=0;video_hs<=0;video_vs<=0;
            hs_q<=0;vs_q<=0;de_q<=0;width<=768;height<=280;
            pixels<=0; lines<=0; vs_gap<=0; line_pending<=0;
        end else begin
            if(de && ce) pixels<=pixels+1'b1;
            if(de_q && !de) begin width<=pixels; pixels<=0; lines<=lines+1'b1; end
            if(vs && !vs_q) begin
                video_vs<=1; video_rgb<={20'b0,field,field,interlaced,1'b0};
                height<=lines; lines<=0; vs_gap<=7; line_pending<=0;
            end else if(vs_gap!=0) vs_gap<=vs_gap-1'b1;
            if(hs && !hs_q && !(vs && !vs_q)) line_pending<=1;
            if(line_pending && vs_gap==0) begin video_hs<=1; line_pending<=0; end
        end
    end
endmodule
