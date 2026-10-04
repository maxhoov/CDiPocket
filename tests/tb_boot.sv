`timescale 1ns/1ps
module tb_boot #(parameter LEGACY_BOOT=0);
    reg sys=0,host=0,reset=1;
    always #16.666667 sys=~sys;
    always #6.734007 host=~host;
    wire [63:0] loader_data;
    wire empty,full,pop;
    reg push=0;
    reg [63:0] loader_input=0;
    pocket_loader_fifo fifo(.wrclk(host),.rdclk(sys),.reset,.wr(push),.rd(pop),
        .data(loader_input),.q(loader_data),.full,.empty);
    wire accepting,ready,idle;
    wire accepting_host,ready_host;
    pocket_sync ac(.clk(host),.d(accepting),.q(accepting_host));
    pocket_sync rc(.clk(host),.d(ready),.q(ready_host));
    wire [12:0] slave_address;
    wire [7:0] slave_data;
    wire slave_write;
    wire [24:0] address;
    wire [15:0] write_data;
    wire read_req,write_req,word_access,burst,refresh,busy;
    pocket_memory manager(.clk(sys),.reset,.core_reset(1'b1),.paused(1'b0),
        .loader_data,.loader_empty(empty),.loader_pop(pop),.accepting,.ready,.idle,
        .slave_addr(slave_address),.slave_data,.slave_wr(slave_write),
        .cdi_addr(25'b0),.cdi_din(16'b0),.cdi_rd(1'b0),.cdi_wr(1'b0),
        .cdi_word(1'b1),.cdi_burst(1'b0),.cdi_refresh(1'b0),.addr(address),
        .din(write_data),.rd(read_req),.wr(write_req),.word(word_access),.burst,.refresh,.busy);
    tri [15:0] dq;
    wire [12:0] dram_address;
    wire [1:0] bank;
    wire nras,ncas,nwe,dram_clock;
    sdram controller(.clk(sys),.init(reset),.addr(address),.din(write_data),.dout(),
        .rd(read_req),.wr(write_req),.word(word_access),.burst,.refresh,.busy,
        .burstdata_valid(),.SDRAM_DQ(dq),.SDRAM_A(dram_address),.SDRAM_BA(bank),
        .SDRAM_DQML(),.SDRAM_DQMH(),.SDRAM_nCS(),.SDRAM_nWE(nwe),
        .SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_CLK(dram_clock),.SDRAM_CKE());
    integer clear_writes=0,slave_bytes=0;
    reg [7:0] slave[0:8191];
    real last_refresh=0;
    integer refreshes=0;
    always @(posedge sys) if(slave_write) begin
        slave[slave_address]=slave_data;slave_bytes=slave_bytes+1;
    end
    always @(posedge dram_clock) begin
        if({nras,ncas,nwe}==3'b100 && address<1048576) begin
            if(dq!==16'b0) $fatal(1,"Nonzero RAM clear data");
            clear_writes=clear_writes+1;
        end
        if({nras,ncas,nwe}==3'b001 && accepting && !ready) begin
            if(refreshes && $realtime-last_refresh>8000)
                $fatal(1,"SDRAM refresh gap during Setup: %0.3f us",($realtime-last_refresh)/1000);
            last_refresh=$realtime;refreshes=refreshes+1;
        end
    end
    wire boot_done,running,reset_n;
    pocket_boot_status boot_status(.pll_locked(!reset),
        .memory_accepting(LEGACY_BOOT ? ready_host : accepting_host),
        .setup_done(ready_host),.reset_n,.loading(1'b0),.boot_done,.running);
    reg [31:0] bridge_addr=0,bridge_data=0;
    reg bridge_wr=0,bridge_rd=0;
    wire [31:0] bridge_q;
    core_bridge_cmd commands(.clk(host),.reset_n,.bridge_endian_little(1'b0),
        .bridge_addr,.bridge_rd,.bridge_wr,.bridge_wr_data(bridge_data),.bridge_rd_data(bridge_q),
        .status_boot_done(boot_done),.status_setup_done(ready_host),.status_running(running),
        .dataslot_requestread(),.dataslot_requestread_id(),.dataslot_requestread_ack(1'b1),
        .dataslot_requestread_ok(1'b1),.dataslot_requestwrite(),.dataslot_requestwrite_id(),
        .dataslot_requestwrite_size(),.dataslot_requestwrite_ack(1'b1),.dataslot_requestwrite_ok(1'b1),
        .dataslot_update(),.dataslot_update_id(),.dataslot_update_size(),.dataslot_allcomplete(),
        .rtc_epoch_seconds(),.rtc_date_bcd(),.rtc_time_bcd(),.rtc_valid(),.osnotify_inmenu(),
        .savestate_supported(1'b0),.savestate_addr(32'b0),.savestate_size(32'b0),
        .savestate_maxloadsize(32'b0),.savestate_start(),.savestate_start_ack(1'b0),
        .savestate_start_busy(1'b0),.savestate_start_ok(1'b0),.savestate_start_err(1'b0),
        .savestate_load(),.savestate_load_ack(1'b0),.savestate_load_busy(1'b0),
        .savestate_load_ok(1'b0),.savestate_load_err(1'b0),.target_dataslot_read(1'b0),
        .target_dataslot_write(1'b0),.target_dataslot_getfile(1'b0),.target_dataslot_openfile(1'b0),
        .target_dataslot_id(16'b0),.target_dataslot_slotoffset(32'b0),.target_dataslot_bridgeaddr(32'b0),
        .target_dataslot_length(32'b0),.target_buffer_param_struct(32'b0),.target_buffer_resp_struct(32'b0),
        .target_dataslot_ack(),.target_dataslot_done(),.target_dataslot_err(),
        .datatable_addr(10'b0),.datatable_wren(1'b0),.datatable_data(32'b0),.datatable_q());
    task automatic command(input [15:0] op,output [31:0] result);
        @(negedge host);bridge_addr=32'hf8000000;bridge_data={16'h434d,op};bridge_wr=1;
        @(negedge host);bridge_wr=0;
        repeat(12) @(posedge host);
        @(negedge host);bridge_rd=1;
        @(negedge host);bridge_rd=0;
        #1;result=bridge_q;
    endtask
    initial begin
        reg [31:0] result;
        #200;@(negedge sys);reset=0;
        wait(accepting_host);
        if($realtime>1000000) $fatal(1,"Physical memory initialization took over 1 ms");
        if(ready) $fatal(1,"Test failed to exercise background RAM clear");
        $display("PASS asset ingress ready at %0.3f ms while full 1 MiB clear is pending",$realtime/1000000);
        // Match APF's first status poll after its 100 ms bitstream delay.
        #99500000;
        for(integer i=0;i<10;i=i+1) begin
            command(16'h0000,result);
            if(result!==32'h4f4b0002) begin
                $display("Request Status %0d: %h; RAM ready=%0d",i,result,ready);
                if(!LEGACY_BOOT) $fatal(1,"Boot poll did not reach Setup before RAM clear");
            end
        end
        if(LEGACY_BOOT) $fatal(1,"Reproduced all ten Request Status results 0001: APF boot timeout");
        command(16'h0011,result);
        if(running) $fatal(1,"CD-i started before full RAM initialization");
        wait(ready_host);
        if(clear_writes!=524288 || refreshes<1000) $fatal(1,"Incomplete RAM clear or refresh");
        command(16'h0000,result);
        if(result!==32'h4f4b0004) $fatal(1,"Core failed to report Running after clear: %h",result);
        $display("PASS ten boot polls, full %0d-word clear and %0d refreshes; complete at %0.3f ms",
            clear_writes,refreshes,$realtime/1000000);
        $display("ALL BOOT TESTS PASSED");$finish;
    end
    initial begin
        // Load all 8 KiB of Slave ROM during the clear, faster than the real
        // Bridge. The loader must preempt clearing and never overflow.
        #2000000;
        for(integer i=0;i<2048;i=i+1) begin
            @(negedge host);
            if(full) $fatal(1,"Asset FIFO overflow during background clear");
            loader_input={32'h20000000+32'(i*4),32'h01234567 ^ 32'(i)};push=1;
            @(negedge host);push=0;
            #375;
        end
        wait(empty && slave_bytes==8192);
        if(ready) $fatal(1,"Assets were not loaded during RAM clearing");
        for(integer i=0;i<2048;i=i+1)
            if({slave[i*4],slave[i*4+1],slave[i*4+2],slave[i*4+3]}!==(32'h01234567 ^ 32'(i)))
                $fatal(1,"Slave firmware byte order/data lost at word %0d",i);
        $display("PASS 8 KiB Slave load preempts background clear without FIFO overflow");
    end
    initial begin #140000000;$fatal(1,"Full-size boot test timed out");end
endmodule
