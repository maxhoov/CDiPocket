`timescale 1ns/1ps
module tb_memory;
    reg clk=0,host=0,reset=1,core_reset=1;
    always #16.666667 clk=~clk;
    always #6.734007 host=~host;
    wire [63:0] loader_data;
    wire loader_empty,loader_full,loader_pop;
    reg loader_write=0;
    reg [63:0] loader_input=0;
    pocket_loader_fifo fifo(.wrclk(host),.rdclk(clk),.reset(reset),.wr(loader_write),
        .rd(loader_pop),.data(loader_input),.q(loader_data),.full(loader_full),.empty(loader_empty));
    reg [24:0] cdi_addr=0;
    reg [15:0] cdi_din=0;
    reg cdi_rd=0,cdi_wr=0,cdi_word=1,cdi_burst=0;
    wire ready,idle;
    wire [12:0] slave_addr;
    wire [7:0] slave_data;
    wire slave_wr;
    wire [24:0] addr;
    wire [15:0] din,dout;
    wire rd,wr,word,burst,refresh,busy,valid;
    pocket_memory #(.RAM_BYTES(4096)) manager(.clk,.reset,.core_reset,.paused(1'b0),.loader_data,
        .loader_empty,.loader_pop,.ready,.idle,.slave_addr,.slave_data,.slave_wr,
        .cdi_addr,.cdi_din,.cdi_rd,.cdi_wr,.cdi_word,.cdi_burst,.cdi_refresh(1'b0),
        .addr,.din,.rd,.wr,.word,.burst,.refresh,.busy);
    wire [15:0] dq;
    wire [12:0] a;
    wire [1:0] ba,dqm;
    wire dram_clk,nwe,nras,ncas;
    sdram controller(.clk,.init(reset),.addr,.din,.dout,.rd,.wr,.word,.burst,.refresh,
        .busy,.burstdata_valid(valid),.SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),
        .SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),.SDRAM_nCS(),
        .SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_CLK(dram_clk),.SDRAM_CKE());
    reg [15:0] memory[int unsigned];
    reg [12:0] row[4];
    reg [15:0] drive=0;
    reg drive_enable=0,read_active=0;
    integer delay_count=0,burst_index=0,base=0;
    integer writes=0;
    assign dq=drive_enable ? drive : 16'hzzzz;
    // MT48LC32M16A2: 13 row bits, 10 column bits, 4 banks,
    // CL=2 (data driven following the first edge, valid by the second).
    always @(posedge dram_clk) begin
        integer location;
        if(read_active) begin
            if(delay_count!=0) delay_count=delay_count-1;
            if(delay_count==0) begin
                location=(base & ~3) | ((base+burst_index)&3);
                drive_enable<=#5 1;
                drive<=#5 memory.exists(location) ? memory[location] : 16'h0000;
                burst_index=burst_index+1;
                if(burst_index==4) read_active=0;
            end
        end else drive_enable<=#5 0;
        case({nras,ncas,nwe})
            3'b011: row[ba]=a;
            3'b101: begin
                base=(int'(ba)<<23) | (int'(row[ba])<<10) | a[9:0];
                burst_index=0;delay_count=1;read_active=1;
            end
            3'b100: begin
                location=(int'(ba)<<23) | (int'(row[ba])<<10) | a[9:0];
                if(!memory.exists(location)) memory[location]=0;
                if(!dqm[0]) memory[location][7:0]=dq[7:0];
                if(!dqm[1]) memory[location][15:8]=dq[15:8];
                writes=writes+1;
            end
        endcase
    end
    reg [7:0] slave_rom[8192];
    always @(posedge clk) if(slave_wr) slave_rom[slave_addr]=slave_data;
    task automatic load_word(input [31:0] address,input [31:0] value);
        @(negedge host);loader_input={address,value};loader_write=1;
        @(negedge host);loader_write=0;
    endtask
    task automatic transact(input [24:0] address,input bit write_access,
        input bit word_access,input [15:0] value,input [15:0] expected);
        @(negedge clk);cdi_addr=address;cdi_wr=write_access;cdi_rd=!write_access;
        cdi_word=word_access;cdi_din=value;
        wait(busy);@(negedge clk);cdi_wr=0;cdi_rd=0;
        wait(!busy);#1;
        if(!write_access && dout!==expected) $fatal(1,"SDRAM read %h expected %h got %h",address,expected,dout);
        repeat(2) @(negedge clk);
    endtask
    initial begin
        #200;@(negedge clk) reset=0;
        wait(ready);#1;
        if(writes!=2048) $fatal(1,"RAM clear wrote %d words",writes);
        for(integer i=0;i<2048;i=i+1)
            if(!memory.exists(i) || memory[i]!==0) $fatal(1,"RAM clear missed %d",i);
        $display("PASS deterministic RAM clear and Pocket SDRAM geometry");
        load_word(32'h100007fc,32'h12345678);
        load_word(32'h10000800,32'h9abcdef0);
        load_word(32'h20000400,32'h11223344);
        repeat(500) @(posedge clk);wait(idle);#1;
        if(memory[32'h4007fc/2]!==16'h1234 || memory[32'h4007fe/2]!==16'h5678 ||
           memory[32'h400800/2]!==16'h9abc || memory[32'h400802/2]!==16'hdef0)
            $fatal(1,"ROM bridge split/order/row boundary failed");
        if(slave_rom[1024]!==8'h11 || slave_rom[1025]!==8'h22 ||
           slave_rom[1026]!==8'h33 || slave_rom[1027]!==8'h44)
            $fatal(1,"Slave firmware byte order failed");
        $display("PASS queued BIOS and Slave ROM loading, including row boundary");
        @(negedge clk);core_reset=0;
        transact(25'h4007fc,0,1,0,16'h1234);
        transact(25'h400800,0,1,0,16'h9abc);
        transact(25'h000004,1,1,16'h1234,0);
        transact(25'h000005,1,0,16'h00aa,0); // upstream's high-byte lane select
        transact(25'h000004,0,1,0,16'haa34);
        transact(25'h000004,1,0,16'h00bb,0);
        transact(25'h000004,0,1,0,16'haabb);
        $display("PASS SDRAM CAS reads and both byte-write masks");
        for(integer i=0;i<4;i=i+1) transact(25'h000010+i*2,1,1,16'h100+i,0);
        @(negedge clk);cdi_burst=1;cdi_rd=1;cdi_addr=25'h000010;
        wait(busy);@(negedge clk);cdi_rd=0;
        begin
            integer count=0;
            while(count!=4) begin
                @(posedge clk);
                if(valid) begin
                    if(dout!==16'h100+count) $fatal(1,"Burst word %d got %h",count,dout);
                    count=count+1;
                end
            end
        end
        $display("PASS all four SDRAM burst words and valid timing");
        $display("ALL MEMORY TESTS PASSED");$finish;
    end
    initial begin #5000000;$fatal(1,"memory timeout manager=%d SDRAM=%d mode=%d writes=%d",manager.state,controller.state,controller.mode,writes);end
endmodule
