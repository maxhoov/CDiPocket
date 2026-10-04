`timescale 1ns/1ps
// Real startup/file arbiter, command handler, RV32I firmware, FIFO and SDRAM
// controller. Host follows the captured OS order: no file service before RTR.
module tb_startup #(parameter LEGACY_STARTUP=0, BIOS_FAILURE=0);
    `include "fixtures/params.svh"
    reg host=0,sys=0,reset=1;
    always #6.734007 host=~host;
    always #16.666667 sys=~sys;
    reg [31:0] bridge_addr=0,bridge_data=0;
    reg bridge_wr=0,bridge_rd=0;
    wire [31:0] bridge_q,command_q,disc_q;
    wire reset_n,request_write,allcomplete;
    wire [15:0] write_id;
    wire [31:0] write_size;
    reg assets_complete=0,slave_seen=0;
    always @(posedge host) begin
        if(request_write) assets_complete<=0;
        if(request_write && write_id==2) slave_seen<=write_size==8192;
        if(allcomplete) assets_complete<=1;
    end
    wire accepting,ready_memory,idle_memory,accepting_host,idle_host;
    wire full,empty,pop;
    wire [63:0] loader_q;
    wire asset_write=bridge_wr &&
        (bridge_addr[31:19]==13'h200 || bridge_addr[31:13]==19'h10000);
    reg overflow=0;
    always @(posedge host) if(asset_write && full) overflow<=1;
    pocket_loader_fifo fifo(.wrclk(host),.rdclk(sys),.reset,
        .wr(asset_write && !full),.rd(pop),.data({bridge_addr,bridge_data}),
        .q(loader_q),.full,.empty);
    pocket_sync ac(.clk(host),.d(accepting),.q(accepting_host));
    pocket_sync id(.clk(host),.d(idle_memory),.q(idle_host));
    wire [24:0] memory_address;
    wire [15:0] memory_data;
    wire memory_rd,memory_wr,memory_word,memory_burst,memory_refresh,memory_busy;
    wire machine_ready,framework_ready,files_enabled;
    wire bios_seen,disc_ready;
    wire file_gate=LEGACY_STARTUP ? assets_complete : files_enabled;
    wire setup_done=LEGACY_STARTUP ? machine_ready : framework_ready;
    pocket_startup startup(.clk(host),.reset,.reset_n,.loading(1'b0),.assets_complete,
        .memory_accepting(accepting_host),.memory_idle(idle_host),.slave_seen,.bios_seen,
        .disc_ready,.loader_overflow(overflow),.framework_ready,.files_enabled,.machine_ready);
    wire core_reset;
    pocket_reset cpu_reset(.clk(sys),.release_n(reset_n && machine_ready),.reset(core_reset));
    wire [12:0] slave_address;
    wire [7:0] slave_data;
    wire slave_wr;
    // Full BIOS/Slave capacity; the independent tb_boot retains 1 MiB clear.
    pocket_memory #(.RAM_BYTES(4096)) memory(.clk(sys),.reset,.core_reset,.paused(1'b0),
        .loader_data(loader_q),.loader_empty(empty),.loader_pop(pop),.accepting,
        .ready(ready_memory),.idle(idle_memory),.slave_addr(slave_address),.slave_data,.slave_wr,
        .cdi_addr(25'b0),.cdi_din(16'b0),.cdi_rd(1'b0),.cdi_wr(1'b0),
        .cdi_word(1'b1),.cdi_burst(1'b0),.cdi_refresh(1'b0),.addr(memory_address),
        .din(memory_data),.rd(memory_rd),.wr(memory_wr),.word(memory_word),
        .burst(memory_burst),.refresh(memory_refresh),.busy(memory_busy));
    tri [15:0] dq;
    wire dram_clock,nras,ncas,nwe;
    wire [12:0] dram_address;
    wire [1:0] dram_bank;
    sdram dram(.clk(sys),.init(reset),.addr(memory_address),.din(memory_data),.dout(),
        .rd(memory_rd),.wr(memory_wr),.word(memory_word),.burst(memory_burst),
        .refresh(memory_refresh),.busy(memory_busy),.burstdata_valid(),.SDRAM_DQ(dq),
        .SDRAM_A(dram_address),.SDRAM_BA(dram_bank),.SDRAM_DQML(),.SDRAM_DQMH(),.SDRAM_nCS(),
        .SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_CLK(dram_clock),.SDRAM_CKE());
    function automatic [31:0] bios_word(input [31:0] offset);
        bios_word=32'ha55a1234 ^ offset;
    endfunction
    integer bios_words=0,slave_bytes=0,bios_chunks=0,open_count=0,save_count=0;
    reg [12:0] active_row[0:3];
    always @(posedge dram_clock) begin
        reg [31:0] physical_address,expected_word;
        if({nras,ncas,nwe}==3'b011) active_row[dram_bank]=dram_address;
        if({nras,ncas,nwe}==3'b100) begin
            physical_address=((32'(dram_bank)<<23) | (32'(active_row[dram_bank])<<10) | dram_address[9:0])<<1;
            if(physical_address>=32'h400000) begin
                if(physical_address!==32'h400000+bios_words*2) $fatal(1,"BIOS write out of order %h",physical_address);
                expected_word=bios_word((bios_words*2)&32'hfffffffc);
                if(dq!==(bios_words%2 ? expected_word[15:0] : expected_word[31:16]))
                    $fatal(1,"BIOS data mismatch at %h",physical_address);
                bios_words=bios_words+1;
            end
        end
    end
    always @(posedge sys) if(slave_wr) begin
        if(slave_address!==13'(slave_bytes) || slave_data!==8'(slave_bytes))
            $fatal(1,"Slave data mismatch at %h",slave_address);
        slave_bytes=slave_bytes+1;
    end
    always @(posedge sys) if(!reset && !core_reset &&
        (!bios_seen || !disc_ready || bios_words!=262144 || slave_bytes!=8192 || overflow))
        $fatal(1,"CD-i CPU released before its files were initialized");
    wire target_read,target_write,target_getfile,target_openfile,target_ack,target_done;
    wire [15:0] target_id;
    wire [31:0] target_offset,target_address,target_length;
    wire [2:0] target_error,boot_error,save_error,disc_error;
    wire nv_freeze,in_menu;
    reg nv_changed=0;
    wire disc_request,disc_grant,disc_done;
    wire [1:0] disc_operation;
    wire [15:0] disc_slot;
    wire [31:0] disc_offset,disc_address,disc_length,diagnostic;
    pocket_file_io files(.clk(host),.reset,.files_enabled(file_gate),.memory_idle(idle_host),
        .bios_size(32'd524288),.nv_allowed(!nv_freeze),.nv_changed,.in_menu,
        .disc_request,.disc_operation,.disc_slot,.disc_offset,.disc_address,.disc_length,
        .disc_grant,.disc_done,.disc_error,.target_ack,.target_done,.target_error,
        .target_read,.target_write,.target_getfile,.target_openfile,.target_id,
        .target_offset,.target_address,.target_length,.bios_seen,.nv_save_freeze(nv_freeze),
        .save_error,.boot_error);
    wire write_ack,write_ok;
    pocket_slot_policy policy(.memory_accepting(accepting_host),.nv_allowed(1'b0),
        .read_id(16'd3),.write_id,.write_size,.read_ack(),.read_ok(),.write_ack,.write_ok);
    wire [9:0] table_address;
    wire [31:0] table_q;
    core_bridge_cmd commands(.clk(host),.reset_n,.bridge_endian_little(1'b0),
        .bridge_addr,.bridge_rd,.bridge_wr,.bridge_wr_data(bridge_data),.bridge_rd_data(command_q),
        .status_boot_done(accepting_host),.status_setup_done(setup_done),
        .status_running(reset_n && setup_done),
        .dataslot_requestread(),.dataslot_requestread_id(),.dataslot_requestread_ack(1'b1),
        .dataslot_requestread_ok(1'b1),.dataslot_requestwrite(request_write),
        .dataslot_requestwrite_id(write_id),.dataslot_requestwrite_size(write_size),
        .dataslot_requestwrite_ack(write_ack),.dataslot_requestwrite_ok(write_ok),
        .dataslot_update(),.dataslot_update_id(),.dataslot_update_size(),.dataslot_allcomplete(allcomplete),
        .rtc_epoch_seconds(),.rtc_date_bcd(),.rtc_time_bcd(),.rtc_valid(),.osnotify_inmenu(in_menu),
        .savestate_supported(1'b0),.savestate_addr(32'b0),.savestate_size(32'b0),
        .savestate_maxloadsize(32'b0),.savestate_start(),.savestate_start_ack(1'b0),
        .savestate_start_busy(1'b0),.savestate_start_ok(1'b0),.savestate_start_err(1'b0),
        .savestate_load(),.savestate_load_ack(1'b0),.savestate_load_busy(1'b0),
        .savestate_load_ok(1'b0),.savestate_load_err(1'b0),
        .target_dataslot_read(target_read),.target_dataslot_write(target_write),
        .target_dataslot_getfile(target_getfile),.target_dataslot_openfile(target_openfile),
        .target_dataslot_id(target_id),.target_dataslot_slotoffset(target_offset),
        .target_dataslot_bridgeaddr(target_address),.target_dataslot_length(target_length),
        .target_buffer_param_struct(target_address),.target_buffer_resp_struct(target_address),
        .target_dataslot_ack(target_ack),.target_dataslot_done(target_done),.target_dataslot_err(target_error),
        .datatable_addr(table_address),.datatable_wren(1'b0),.datatable_data(32'b0),.datatable_q(table_q));
    pocket_native_disc #(.INIT_FILE("../../src/fpga/core/native_disc/firmware.mif")) disc (
        .clk_bridge(host),.clk_sys(sys),.reset,.machine_reset(core_reset),.assets_complete(file_gate),
        .cue_size(32'(CUE_LENGTH)),.bridge_addr,.bridge_wr,.bridge_data,.bridge_q(disc_q),
        .ready(disc_ready),.diagnostic,.request(disc_request),.operation(disc_operation),.slot(disc_slot),
        .file_offset(disc_offset),.buffer_address(disc_address),.length(disc_length),
        .grant(disc_grant),.done(disc_done),.error(disc_error),.datatable_addr(table_address),
        .datatable_q(table_q),.cache_lba(32'b0),.cache_req(1'b0),.cache_ack(),.cache_data(),
        .cache_valid(),.last_error());
    pocket_bridge_reply reply(.clk(host),.rd(bridge_rd),.addr(bridge_addr),
        .command_data(command_q),.disc_data(disc_q),.nvram_data(32'hffffffff),
        .register_data(diagnostic),.q(bridge_q));
    task automatic write_word(input [31:0] location,input [31:0] value);
        @(negedge host);bridge_addr=location;bridge_data=value;bridge_wr=1;
        @(negedge host);bridge_wr=0;
        // Direct bus driving must retain the SPI link's finite throughput.
        // 32 host clocks per asset word is approximately 9.3 MB/s.
        if(location[31:24]==8'h10 || location[31:24]==8'h20)
            repeat(30) @(negedge host);
    endtask
    task automatic read_word(input [31:0] location,output [31:0] value);
        @(negedge host);bridge_addr=location;bridge_rd=1;
        @(negedge host);bridge_rd=0;
        repeat(3) @(negedge host);
        value=bridge_q;
    endtask
    task automatic host_command(input [15:0] command,input [15:0] expected);
        reg [31:0] value;
        write_word(32'hf8000000,{16'h434d,command});
        for(integer i=0;i<16;i=i+1) begin
            read_word(32'hf8000000,value);
            if(value[31:16]===16'h4f4b) begin
                if(value[15:0]!==expected) $fatal(1,"Host %h returned %h",command,value);
                return;
            end
        end
        $fatal(1,"Host command timeout %h",command);
    endtask
    task automatic slot_info(input integer index,input [15:0] id,input [31:0] size);
        write_word(32'hf8002000+index*8,{16'b0,id});
        write_word(32'hf8002004+index*8,size);
    endtask
    reg [7:0] cue[0:CUE_LENGTH-1],path[0:255];
    integer current_file=-1;
    initial begin : captured_host_order
        reg [31:0] value,op_id,op_offset,op_address,op_length,word;
        reg [7:0] byte_value;
        reg [2:0] result;
        string filename;
        $readmemh("fixtures/cue.hex",cue);$readmemh("fixtures/path.hex",path);
        repeat(10) @(posedge host);
        @(negedge host);reset=0;
        wait(idle_host);
        host_command(16'h0000,2);host_command(16'h00b1,0);
        write_word(32'hf8000020,0);write_word(32'hf8000024,CUE_LENGTH);host_command(16'h0082,0);
        slot_info(0,0,CUE_LENGTH);
        write_word(32'hf8000020,1);write_word(32'hf8000024,524288);host_command(16'h0082,0);
        slot_info(1,1,524288);
        write_word(32'hf8000020,2);write_word(32'hf8000024,8192);host_command(16'h0082,0);
        for(integer i=0;i<8192;i=i+4)
            write_word(32'h20000000+i,{8'(i),8'(i+1),8'(i+2),8'(i+3)});
        slot_info(2,2,8192);slot_info(3,3,0);slot_info(4,4,0);
        host_command(16'h008f,0);host_command(16'h0090,0);host_command(16'h00b2,0);
        // Just like APF, do not handle 0180/0190/0192 before this check.
        read_word(32'hf8001000,value);
        if(value!==32'h636d0140)
            $fatal(1,"Core not ready to run: target register %h framework=%b assets=%b slave=%b overflow=%b",
                value,framework_ready,assets_complete,slave_seen,overflow);
        if(!core_reset || bios_seen || disc_ready) $fatal(1,"Framework readiness released CD-i CPU");
        $display("PASS Ready to Run precedes all deferred file operations; CD-i CPU remains reset");
        write_word(32'hf8001000,32'h6f6b0000);
        host_command(16'h0011,0);host_command(16'h0000,4);
        // Complete every real target operation through its command registers.
        while(!machine_ready || save_count==0) begin
            read_word(32'hf8001000,value);
            if(value[31:16]!==16'h636d) begin
                if(machine_ready && save_count==0) begin
                    @(negedge host);nv_changed=1;@(negedge host);nv_changed=0;
                    write_word(32'hf8000020,1);host_command(16'h00b0,0);
                end
                continue;
            end
            read_word(32'hf8001020,op_id);read_word(32'hf8001024,op_offset);
            read_word(32'hf8001028,op_address);read_word(32'hf800102c,op_length);
            write_word(32'hf8001000,32'h62750000);
            result=0;
            case(value[15:0])
                16'h0180: if(op_id==1) begin
                    if(op_offset!==32'(bios_chunks*4096) || op_address!==32'h10000000+op_offset || op_length!=4096)
                        $fatal(1,"BIOS chunk geometry %h %h %h",op_offset,op_address,op_length);
                    if(BIOS_FAILURE) result=2;
                    else for(integer i=0;i<4096;i=i+4) write_word(op_address+i,bios_word(op_offset+i));
                    bios_chunks=bios_chunks+1;
                    if(bios_chunks%32==0) $display("Startup progress: %0d / 128 BIOS chunks",bios_chunks);
                end else if(op_id==0) begin
                    if(op_offset!=0 || op_length!=CUE_LENGTH) $fatal(1,"CUE read geometry");
                    for(integer i=0;i<op_length;i=i+4) begin
                        word=0;
                        for(integer b=0;b<4;b=b+1) if(i+b<op_length) word[31-b*8 -: 8]=cue[i+b];
                        write_word(op_address+i,word);
                    end
                end else $fatal(1,"Unexpected startup read slot %h",op_id);
                16'h0190: begin
                    if(op_id!=0) $fatal(1,"Filename slot %h",op_id);
                    for(integer i=0;i<256;i=i+4) write_word(op_offset+i,{path[i],path[i+1],path[i+2],path[i+3]});
                end
                16'h0192: begin
                    filename="";
                    for(integer i=0;i<256;i=i+4) begin
                        read_word(op_offset+i,word);
                        for(integer b=0;b<4;b=b+1) begin
                            byte_value=word[31-b*8 -: 8];
                            if(byte_value==0) break;
                            filename={filename,byte_value};
                        end
                        if(byte_value==0) break;
                    end
                    if(op_id!=4) $fatal(1,"Open slot %h",op_id);
                    if(filename=="/Assets/cdi/common/Game/mixed data.bin") current_file=0;
                    else if(filename=="/Assets/cdi/common/Game/extra.bin") current_file=1;
                    else $fatal(1,"Unexpected file %s",filename);
                    read_word(op_offset+256,word);if(word!=0) $fatal(1,"Open can modify an asset");
                    slot_info(4,4,current_file==0 ? 11760 : 4704);open_count=open_count+1;
                end
                16'h0184: begin
                    if(!nv_freeze || op_id!=3 || op_length!=8192) $fatal(1,"NVRAM save handshake");
                    save_count=save_count+1;
                end
                default: $fatal(1,"Unexpected target command %h",value);
            endcase
            write_word(32'hf8001000,{16'h6f6b,13'b0,result});
            if(BIOS_FAILURE) begin
                wait(boot_error==2);repeat(50) @(posedge host);
                if(machine_ready || !core_reset || bios_seen) $fatal(1,"BIOS failure released CPU");
                $display("ALL STARTUP FAILURE TESTS PASSED");$finish;
            end
        end
        wait(!core_reset);wait(!nv_freeze);
        if(bios_chunks!=128 || bios_words!=262144 || slave_bytes!=8192 || overflow || open_count!=2 || diagnostic!=0)
            $fatal(1,"Incomplete startup bios=%0d words=%0d slave=%0d opens=%0d diagnostic=%h",bios_chunks,bios_words,slave_bytes,open_count,diagnostic);
        $display("PASS full 512 KiB BIOS and 8 KiB Slave transfer, FIFO drain and actual CUE/BIN firmware startup");
        host_command(16'h0010,0);repeat(12) @(posedge sys);
        if(!core_reset || !framework_ready || files_enabled) $fatal(1,"Reset Enter lost framework state");
        host_command(16'h0011,0);wait(!core_reset);
        if(boot_error || save_error || save_count!=1) $fatal(1,"Startup/save failed");
        $display("PASS menu save and Reset Enter/Exit without another framework startup");
        $display("ALL STARTUP TESTS PASSED");$finish;
    end
    initial begin #300000000;$fatal(1,"Startup timed out diagnostic=%h bios=%0d target=%h",diagnostic,bios_chunks,commands.target_0);end
endmodule
