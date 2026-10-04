`timescale 1ns/1ps
// Exercise the actual two-bit SPI transport, including its previous-word
// reply pipeline. No state-machine registers are forced or initialized here.
module tb_framework;
    reg clk=0;
    always #6.734007 clk=~clk;
    tri spiclk,mosi,miso;
    reg select_n=1,drive=0,host_clock=0;
    reg [1:0] host_pair=0;
    assign spiclk=drive ? host_clock : 1'bz;
    assign mosi=drive ? host_pair[1] : 1'bz;
    assign miso=drive ? host_pair[0] : 1'bz;
    wire [31:0] addr,write_data,read_data,command_data;
    wire rd,wr,reset_n,in_menu;
    wire machine_clk,paused,mute;
    pocket_pause pause_control(.clk,.core_reset(!reset_n),.in_menu,.vblank(1'b1),
        .memory_idle(1'b1),.memory_busy(1'b0),.memory_valid(1'b0),.cdi_rd(1'b0),.cdi_wr(1'b0),
        .clk_machine(machine_clk),.paused,.mute);
    integer machine_cycles=0;
    always @(posedge machine_clk) machine_cycles=machine_cycles+1;
    io_bridge_peripheral transport(.clk,.reset_n,.endian_little(1'b0),
        .pmp_addr(addr),.pmp_addr_valid(),.pmp_rd(rd),.pmp_wr(wr),
        .pmp_wr_data(write_data),.pmp_rd_data(read_data),
        .phy_spiclk(spiclk),.phy_spimosi(mosi),.phy_spimiso(miso),.phy_spiss(select_n));
    reg boot_done=0,setup_done=0;
    wire running=reset_n && setup_done;
    wire request_read,request_write,allcomplete;
    wire [15:0] read_id,write_id;
    wire [31:0] write_size;
    // A genuine consumer waits for NVRAM to become quiescent.
    reg nv_frozen=0;
    reg [2:0] freeze_delay=0;
    always @(posedge clk) if(request_write && write_id==3) begin
        if(freeze_delay==4) nv_frozen<=1;
        else freeze_delay<=freeze_delay+1;
    end
    wire read_ack,read_ok,write_ack,write_ok;
    // Use the production policy, including permission for deferred assets.
    pocket_slot_policy slot_policy(.memory_accepting(1'b1),.nv_allowed(!nv_frozen),
        .read_id,.write_id,.write_size,.read_ack,.read_ok,.write_ack,.write_ok);
    reg target_read=0,target_getfile=0,target_openfile=0;
    wire target_ack,target_done;
    wire [2:0] target_error;
    core_bridge_cmd commands(.clk,.reset_n,.bridge_endian_little(1'b0),
        .bridge_addr(addr),.bridge_rd(rd),.bridge_wr(wr),.bridge_wr_data(write_data),
        .bridge_rd_data(command_data),.status_boot_done(boot_done),
        .status_setup_done(setup_done),.status_running(running),
        .dataslot_requestread(request_read),.dataslot_requestread_id(read_id),
        .dataslot_requestread_ack(read_ack),.dataslot_requestread_ok(read_ok),
        .dataslot_requestwrite(request_write),.dataslot_requestwrite_id(write_id),
        .dataslot_requestwrite_size(write_size),.dataslot_requestwrite_ack(write_ack),
        .dataslot_requestwrite_ok(write_ok),.dataslot_update(),.dataslot_update_id(),
        .dataslot_update_size(),.dataslot_allcomplete(allcomplete),
        .rtc_epoch_seconds(),.rtc_date_bcd(),.rtc_time_bcd(),.rtc_valid(),.osnotify_inmenu(in_menu),
        .savestate_supported(1'b0),.savestate_addr(32'b0),.savestate_size(32'b0),
        .savestate_maxloadsize(32'b0),.savestate_start(),.savestate_start_ack(1'b0),
        .savestate_start_busy(1'b0),.savestate_start_ok(1'b0),.savestate_start_err(1'b0),
        .savestate_load(),.savestate_load_ack(1'b0),.savestate_load_busy(1'b0),
        .savestate_load_ok(1'b0),.savestate_load_err(1'b0),
        .target_dataslot_read(target_read),.target_dataslot_write(1'b0),
        .target_dataslot_getfile(target_getfile),.target_dataslot_openfile(target_openfile),
        .target_dataslot_id(16'd4),.target_dataslot_slotoffset(32'h1234),
        .target_dataslot_bridgeaddr(32'h6001e000),.target_dataslot_length(32'd2352),
        .target_buffer_param_struct(32'h60001000),.target_buffer_resp_struct(32'h60002000),
        .target_dataslot_ack(target_ack),.target_dataslot_done(target_done),
        .target_dataslot_err(target_error),.datatable_addr(10'b0),
        .datatable_wren(1'b0),.datatable_data(32'b0),.datatable_q());
    // These RAM outputs follow the current address, as the actual M10Ks do.
    reg [31:0] ram_word=0,nv_word=0;
    always @(posedge clk) begin
        ram_word<=32'h60000000 | addr[23:0];
        nv_word<=32'h40000000 | addr[23:0];
    end
    pocket_bridge_reply reply(.clk,.rd,.addr,.command_data,
        .nvram_data(nv_word),.disc_data(ram_word),.register_data(32'b0),.q(read_data));

    task automatic send_pair(input [1:0] pair);
        host_clock=0;host_pair=pair;#80;
        host_clock=1;#80;
        host_clock=0;#80;
    endtask
    task automatic send_word(input [31:0] word);
        for(integer bit_index=30;bit_index>=0;bit_index=bit_index-2)
            send_pair(word[bit_index +: 2]);
    endtask
    task automatic begin_transaction;
        select_n=1;drive=1;host_clock=0;#200;
        select_n=0;#200;
    endtask
    task automatic end_transaction;
        #250;select_n=1;drive=0;#250;
    endtask
    task automatic write_word(input [31:0] location,input [31:0] value);
        begin_transaction();send_word(location|1);send_word(value);end_transaction();
    endtask
    task automatic read_transaction(input [31:0] location,output [31:0] value);
        begin_transaction();send_word(location);
        drive=0;
        value=0;
        // Bridge takes over and transmits sixteen pairs at 74.25 MHz.
        wait(spiclk===1'b1);
        for(integer i=0;i<16;i=i+1) begin
            @(negedge spiclk);@(posedge spiclk);
            value={value[29:0],mosi,miso};
        end
        end_transaction();
    endtask
    task automatic read_word(input [31:0] location,output [31:0] value);
        reg [31:0] discard;
        read_transaction(location,discard);
        read_transaction(location,value);
    endtask
    task automatic host_command(input [15:0] command,input [15:0] expected);
        reg [31:0] value;
        write_word(32'hf8000000,{16'h434d,command});
        for(integer tries=0;tries<8;tries=tries+1) begin
            read_word(32'hf8000000,value);
            if(value[31:16]===16'h4f4b) begin
                if(value[15:0]!==expected)
                    $fatal(1,"Host command %h returned %h; expected %h",command,value,expected);
                return;
            end
        end
        $fatal(1,"RS: Host commands ignored; command %h response %h",command,value);
    endtask
    task automatic target_command(input [1:0] kind,input [15:0] expected);
        reg [31:0] value;
        @(negedge clk);
        target_read=kind==1;target_getfile=kind==2;target_openfile=kind==3;
        @(negedge clk);target_read=0;target_getfile=0;target_openfile=0;
        read_word(32'hf8001000,value);
        if(value!=={16'h636d,expected}) $fatal(1,"Target command %h",value);
        read_word(32'hf8001020,value);if(value!=4) $fatal(1,"Target ID %h",value);
        read_word(32'hf8001024,value);
        if(value!==(kind==1 ? 32'h1234 : kind==2 ? 32'h60002000 : 32'h60001000))
            $fatal(1,"Target parameter %h",value);
        write_word(32'hf8001000,32'h62750000);wait(target_ack);
        write_word(32'hf8001000,32'h6f6b0000);wait(target_done);
        if(target_error!=0) $fatal(1,"Target completion error");
        repeat(4) @(posedge clk);
    endtask
    initial begin
        reg [31:0] value,discard;
        #1000;
        host_command(16'h0000,1);
        boot_done=1;host_command(16'h0000,2);
        host_command(16'h0010,0);
        host_command(16'h00b1,0);
        host_command(16'h00b2,0);
        $display("PASS cold boot and current OS notifications over physical SPI");
        // OS 2.7 requests permission even for a deferload slot. Follow the
        // captured startup order: CUE permission comes before BIOS/Slave.
        write_word(32'hf8000020,0);write_word(32'hf8000024,77);
        host_command(16'h0082,0);
        write_word(32'hf8000020,1);write_word(32'hf8000024,524288);
        host_command(16'h0082,0);
        write_word(32'hf8000020,2);write_word(32'hf8000024,8192);
        host_command(16'h0082,0);
        write_word(32'hf8000020,3);host_command(16'h0082,0);
        if(!nv_frozen) $fatal(1,"NVRAM acknowledged before its consumer froze");
        host_command(16'h008f,0);
        $display("PASS OS 2.7 CUE-first deferred-slot startup permissions using production policy");
        // A dynamic BIN also requires permission without becoming an
        // automatically loaded asset. Reject bad sizes and unknown IDs.
        write_word(32'hf8000020,4);write_word(32'hf8000024,2352*45000);
        host_command(16'h0082,0);
        write_word(32'hf8000020,0);write_word(32'hf8000024,32769);
        host_command(16'h0082,2);
        write_word(32'hf8000024,32768);host_command(16'h0082,0);
        write_word(32'hf8000020,4);write_word(32'hf8000024,32'h40000001);
        host_command(16'h0082,2);
        write_word(32'hf8000024,32'h40000000);host_command(16'h0082,0);
        write_word(32'hf8000020,5);host_command(16'h0082,2);
        write_word(32'hf8000020,1);write_word(32'hf8000024,8192);
        host_command(16'h0082,2);
        host_command(16'h008f,0);
        $display("PASS BIN slot, size limits and unknown-slot rejection over physical SPI");
        setup_done=1;host_command(16'h0000,3);
        read_word(32'hf8001000,value);
        if(value!==32'h636d0140) $fatal(1,"Missing Ready to Run: %h",value);
        write_word(32'hf8001000,32'h6f6b0000);
        host_command(16'h0011,0);host_command(16'h0000,4);
        target_command(2,16'h0190);target_command(3,16'h0192);target_command(1,16'h0180);
        write_word(32'hf8000020,1);host_command(16'h00b0,0);wait(paused);
        begin
            integer stopped_at;
            stopped_at=machine_cycles;
            host_command(16'h0000,4);
            repeat(32) @(posedge clk);
            if(machine_cycles!=stopped_at || !mute) $fatal(1,"Menu did not freeze the machine");
            write_word(32'hf8000020,0);host_command(16'h00b0,0);wait(!paused);
            repeat(16) @(posedge clk);
            if(machine_cycles==stopped_at || mute) $fatal(1,"Menu exit did not resume the machine");
        end
        $display("PASS OS menu enter/exit pauses and resumes via physical SPI; host remains responsive");
        write_word(32'hf8000020,1);host_command(16'h00b0,0);wait(paused);
        host_command(16'h0010,0);host_command(16'h0000,3);
        if(paused) $fatal(1,"Menu prevented Reset Enter from reaching the machine");
        $display("PASS first-command asset ACK, Ready to Run and running/reset status");
        // Capture a RAM read and switch banks immediately. Its previous-word
        // reply must survive both address and target-bank changes.
        read_transaction(32'h60001234,discard);
        read_transaction(32'hf8000000,value);
        if(value!==32'h60001234) $fatal(1,"Cross-bank reply lost: %h",value);
        read_transaction(32'h40000200,discard);
        read_transaction(32'h60000800,value);
        if(value!==32'h40000200) $fatal(1,"NVRAM reply overwritten: %h",value);
        read_transaction(32'h60000804,value);
        if(value!==32'h60000800) $fatal(1,"BIN filename read shifted: %h",value);
        $display("PASS Bridge reply pipeline across commands, native RAM and NVRAM");
        $display("ALL FRAMEWORK TESTS PASSED");$finish;
    end
    initial begin #5000000;$fatal(1,"Framework SPI test timed out");end
endmodule
