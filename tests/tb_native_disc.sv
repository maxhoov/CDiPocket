`timescale 1ns/1ps
module tb_native_disc;
    `include "fixtures/params.svh"
    reg host=0,sys=0,reset=1,machine_reset=1;
    always #6.734007 host=~host;
    always #16.666667 sys=~sys;
    reg in_menu=0;
    wire machine_clk,paused;
    pocket_pause pause_control(.clk(sys),.core_reset(machine_reset || reset),.in_menu,.vblank(1'b1),
        .memory_idle(1'b1),.memory_busy(1'b0),.memory_valid(1'b0),.cdi_rd(1'b0),.cdi_wr(1'b0),
        .clk_machine(machine_clk),.paused,.mute());
    reg [31:0] bridge_addr=0,bridge_data=0;
    reg bridge_wr=0,grant=0,done=0;
    reg [2:0] error=0;
    wire [31:0] bridge_q,diagnostic;
    wire ready,request;
    wire [1:0] operation;
    wire [15:0] slot;
    wire [31:0] offset,address,length;
    wire [9:0] table_addr;
    reg [31:0] table_q=0;
    reg [31:0] slot_table[0:63];
    always @(posedge host) table_q<=slot_table[table_addr];
    reg [31:0] lba=0;
    reg req=0;
    wire ack,valid;
    wire [15:0] data;
    wire [2:0] last_error;
    pocket_native_disc #(.INIT_FILE("../../src/fpga/core/native_disc/firmware.mif")) dut (
        .clk_bridge(host),.clk_sys(machine_clk),.reset,.machine_reset,.assets_complete(1'b1),
        .cue_size(32'(CUE_LENGTH)),.bridge_addr,.bridge_wr,.bridge_data,.bridge_q,
        .ready,.diagnostic,.request,.operation,.slot,.file_offset(offset),
        .buffer_address(address),.length,.grant,.done,.error,
        .datatable_addr(table_addr),.datatable_q(table_q),.cache_lba(lba),.cache_req(req),
        .cache_ack(ack),.cache_data(data),.cache_valid(valid),.last_error
    );
    reg [7:0] cue[0:CUE_LENGTH-1],bin0[0:11759],bin1[0:4703],path[0:255];
    reg [7:0] expected[0:TEST_SECTORS*2568-1];
    reg [31:0] lbas[0:TEST_SECTORS-1];
    integer current_file=-1,command_count=0,open_count=0,words=0,test_index=-1;
    reg inject_error=0;
    real request_time;
    always @(posedge machine_clk) if(valid) begin
        if(test_index<0 || words>=1284) $fatal(1,"Unexpected sector data");
        if(data!=={expected[test_index*2568+words*2],expected[test_index*2568+words*2+1]})
            $fatal(1,"Native sector %0d word %0d: %h",test_index,words,data);
        words=words+1;
    end
    task automatic write_word(input [31:0] location,input [31:0] value);
        @(negedge host);bridge_addr=location;bridge_data=value;bridge_wr=1;
        @(negedge host);bridge_wr=0;
    endtask
    task automatic read_word(input [31:0] location,output [31:0] value);
        @(negedge host);bridge_addr=location;
        repeat(3) @(posedge host);
        #1;value=bridge_q;
    endtask
    initial begin : apf_host
        reg [31:0] op_address,op_offset,op_length,word;
        reg [15:0] op_slot;
        reg [1:0] op;
        reg [7:0] value;
        string filename;
        for(integer i=0;i<64;i=i+1) slot_table[i]=32'hffff;
        // BIN slot deliberately occupies entry 7, rather than entry 4.
        slot_table[0]=0;slot_table[1]=CUE_LENGTH;slot_table[14]=4;slot_table[15]=0;
        $readmemh("fixtures/cue.hex",cue);$readmemh("fixtures/bin0.hex",bin0);
        $readmemh("fixtures/bin1.hex",bin1);$readmemh("fixtures/path.hex",path);
        $readmemh("fixtures/expected.hex",expected);$readmemh("fixtures/lbas.hex",lbas);
        wait(!reset);
        forever begin
            wait(request);
            op=operation;op_slot=slot;op_address=address;op_offset=offset;op_length=length;
            @(negedge host);grant=1;
            @(negedge host);grant=0;
            command_count=command_count+1;error=0;
            if(op==2) begin
                if(op_slot!=0) $fatal(1,"Get filename slot %d",op_slot);
                for(integer i=0;i<256;i=i+4)
                    write_word(op_address+i,{path[i],path[i+1],path[i+2],path[i+3]});
            end else if(op==3) begin
                filename="";
                for(integer i=0;i<256;i=i+4) begin
                    read_word(op_address+i,word);
                    for(integer b=0;b<4;b=b+1) begin
                        value=word[31-b*8 -: 8];
                        if(value==0) break;
                        filename={filename,value};
                    end
                    if(value==0) break;
                end
                if(op_slot!=4) $fatal(1,"BIN uses slot %d",op_slot);
                if(filename=="/Assets/cdi/common/Game/mixed data.bin") begin current_file=0;slot_table[15]=11760;end
                else if(filename=="/Assets/cdi/common/Game/extra.bin") begin current_file=1;slot_table[15]=4704;end
                else $fatal(1,"Unexpected BIN filename: %s",filename);
                read_word(op_address+256,word);if(word!=0) $fatal(1,"Open flags must be read-only/no-create");
                open_count=open_count+1;
            end else if(op==1) begin
                if(inject_error && op_slot==4) error=2;
                else for(integer i=0;i<op_length;i=i+4) begin
                    word=0;
                    for(integer b=0;b<4;b=b+1) begin
                        if(i+b>=op_length) value=0;
                        else if(op_slot==0) value=cue[op_offset+i+b];
                        else if(op_slot==4 && current_file==0) value=bin0[op_offset+i+b];
                        else if(op_slot==4 && current_file==1) value=bin1[op_offset+i+b];
                        else $fatal(1,"Read without an opened BIN");
                        word[31-b*8 -: 8]=value;
                    end
                    write_word(op_address+i,word);
                end
            end else $fatal(1,"Unsupported native operation: %d",op);
            @(negedge host);done=1;
            @(negedge host);done=0;
        end
    end
    initial begin
        repeat(10) @(posedge host);
        @(negedge host);reset=0;
        wait(ready);
        wait(diagnostic==0);
        if(diagnostic!=0) $fatal(1,"Ready with diagnostic %h",diagnostic);
        $display("PASS actual RV32I firmware CUE startup, quoted names and dynamic BIN sizes");
        $display("PASS native CDI/2352 CUE parsed and BIN opened without conversion");
        @(negedge sys);machine_reset=0;
        repeat(12) @(posedge sys);
        for(integer i=0;i<TEST_SECTORS;i=i+1) begin
            words=0;test_index=i;
            @(negedge sys);lba=lbas[i];req=1;request_time=$realtime;
            wait(ack);@(negedge sys);req=0;
            if(i==2) begin
                // APF finishes a pending sector while the consumer is paused.
                @(negedge sys);in_menu=1;wait(paused);
                begin
                    integer stopped_words;
                    stopped_words=words;
                    wait(dut.cd_state==2);
                    repeat(30) @(posedge host);
                    if(words!=stopped_words) $fatal(1,"Paused sector advanced");
                    @(negedge sys);in_menu=0;wait(!paused);
                end
                $display("PASS pending APF sector completion while paused");
            end
            if(i==3) begin
                // Stop in the middle of a 1284-word stream, even on a valid pulse.
                wait(words==97);@(negedge sys);in_menu=1;wait(paused);
                begin
                    integer stopped_words;
                    stopped_words=words;
                    repeat(300) @(posedge sys);
                    if(words!=stopped_words) $fatal(1,"Paused stream advanced");
                    @(negedge sys);in_menu=0;wait(!paused);
                end
                $display("PASS mid-sector pause preserves streaming position and valid pulses");
            end
            wait(words==1284);wait(!ack);
            $display("PASS native LBA %h: all 1284 words and Q CRC, latency %0.3f ms",lba,($realtime-request_time)/1000000.0);
            repeat(20) @(posedge sys);
        end
        // EOF must publish no partially prepared sector.
        words=0;test_index=0;
        @(negedge sys);lba=287;req=1;
        wait(ack);@(negedge sys);req=0;
        wait(last_error==6);
        repeat(20) @(posedge sys);
        if(words!=0) $fatal(1,"EOF published partial data");
        @(negedge sys);machine_reset=1;
        repeat(12) @(posedge sys);
        @(negedge sys);machine_reset=0;
        repeat(12) @(posedge sys);
        inject_error=1;
        @(negedge sys);lba=150;req=1;
        wait(ack);@(negedge sys);req=0;
        wait(last_error==4);
        if(words!=0) $fatal(1,"I/O failure published partial data");
        $display("PASS native EOF/reset recovery and failed-read suppression");
        if(open_count<3 || command_count<8) $fatal(1,"Dynamic BIN file operations were not exercised");
        $display("ALL NATIVE DISC TESTS PASSED");$finish;
    end
    initial begin #300000000;$fatal(1,"Native firmware timed out, diagnostic %h pc=%h state=%d",diagnostic,dut.file_cpu.reg_pc,dut.cd_state);end
endmodule
