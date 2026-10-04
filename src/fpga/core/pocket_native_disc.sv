// SPDX-License-Identifier: GPL-3.0-or-later
// APF file manager. The RV32I helper handles CUE/BIN metadata, never the
// emulated CD-i CPU. File data stays on SD and is fetched a sector at a time.
module pocket_native_disc #(
    parameter INIT_FILE="core/native_disc/firmware.mif"
) (
    input clk_bridge,input clk_sys,input reset,input machine_reset,
    input assets_complete,input [31:0] cue_size,
    input [31:0] bridge_addr,input bridge_wr,input [31:0] bridge_data,
    output [31:0] bridge_q,
    output ready,output [31:0] diagnostic,
    output reg request=0,output reg [1:0] operation=0,
    output reg [15:0] slot=0,
    output reg [31:0] file_offset=0,buffer_address=0,length=0,
    input grant,input done,input [2:0] error,
    output [9:0] datatable_addr,input [31:0] datatable_q,
    input [31:0] cache_lba,input cache_req,
    output cache_ack,output reg [15:0] cache_data=0,output reg cache_valid=0,
    output [2:0] last_error
);
    function automatic [31:0] reverse_bytes(input [31:0] value);
        reverse_bytes={value[7:0],value[15:8],value[23:16],value[31:24]};
    endfunction
    wire cpu_valid,cpu_instruction,cpu_trap;
    wire [31:0] cpu_addr,cpu_data;
    wire [3:0] cpu_strobes;
    reg cpu_ready=0;
    reg [31:0] cpu_result=0;
    picorv32 #(.ENABLE_COUNTERS(0),.ENABLE_COUNTERS64(0),
        .BARREL_SHIFTER(1),.TWO_CYCLE_ALU(1),.TWO_CYCLE_COMPARE(1),
        .ENABLE_IRQ(0),.ENABLE_MUL(0),.ENABLE_DIV(0),.PROGADDR_RESET(0),
        .STACKADDR(32'h0001df00)) file_cpu (
        .clk(clk_bridge),.resetn(!reset),.trap(cpu_trap),
        .mem_valid(cpu_valid),.mem_instr(cpu_instruction),.mem_ready(cpu_ready),
        .mem_addr(cpu_addr),.mem_wdata(cpu_data),.mem_wstrb(cpu_strobes),
        .mem_rdata(cpu_result),.mem_la_read(),.mem_la_write(),.mem_la_addr(),
        .mem_la_wdata(),.mem_la_wstrb(),.pcpi_valid(),.pcpi_insn(),
        .pcpi_rs1(),.pcpi_rs2(),.pcpi_wr(1'b0),.pcpi_rd(32'b0),
        .pcpi_wait(1'b0),.pcpi_ready(1'b0),.irq(32'b0),.eoi(),
        .trace_valid(),.trace_data()
    );
    reg [2:0] memory_phase=0;
    wire cpu_access=cpu_valid && !cpu_ready && memory_phase==0;
    wire cpu_ram=cpu_addr[31:17]==0;
    wire cpu_write=cpu_access && cpu_ram && |cpu_strobes;
    wire host_ram=bridge_addr[31:17]==15'h3000;
    wire [31:0] ram_q_a,ram_q_b;
    wire [31:0] host_data=reverse_bytes(bridge_data);
    // Both ports use native 32-bit words. APF byte order is converted at the
    // boundary; the helper firmware and its RAM use RISC-V little endian.
    altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),
        .intended_device_family("Cyclone V"),.width_a(32),.width_b(32),
        .widthad_a(15),.widthad_b(15),.numwords_a(32768),.numwords_b(32768),
        .width_byteena_a(4),.width_byteena_b(4),.byte_size(8),
        .address_reg_b("CLOCK1"),.indata_reg_b("CLOCK1"),
        .wrcontrol_wraddress_reg_b("CLOCK1"),.byteena_reg_b("CLOCK1"),
        .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .power_up_uninitialized("FALSE"),.init_file(INIT_FILE),.lpm_type("altsyncram")) ram (
        .clock0(clk_bridge),.clock1(clk_bridge),.address_a(cpu_addr[16:2]),
        .address_b(bridge_addr[16:2]),.data_a(cpu_data),.data_b(host_data),
        .wren_a(cpu_write),.wren_b(bridge_wr && host_ram),
        .byteena_a(cpu_strobes),.byteena_b(4'hf),.q_a(ram_q_a),.q_b(ram_q_b),
        .rden_a(1'b1),.rden_b(1'b1),.aclr0(1'b0),.aclr1(1'b0),
        .addressstall_a(1'b0),.addressstall_b(1'b0),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus()
    );
    assign bridge_q=reverse_bytes(ram_q_b);
    assign datatable_addr={4'b0,cpu_addr[7:2]};
    reg disc_ready=0;
    reg [31:0] progress=0;
    reg io_busy=0,io_done=0;
    reg [2:0] io_error=0;
    reg [2:0] cd_error=0;
    reg [2:0] cd_state=0;
    reg [23:0] token=0;
    reg [31:0] requested_lba=0;
    reg pending=0,busy=0,ready_toggle=0;
    reg stream_done=0;
    wire req_host,done_host,reset_host;
    pocket_sync req_sync(.clk(clk_bridge),.d(cache_req),.q(req_host));
    pocket_sync done_sync(.clk(clk_bridge),.d(stream_done),.q(done_host));
    pocket_sync reset_sync(.clk(clk_bridge),.d(machine_reset),.q(reset_host));
    pocket_sync ack_sync(.clk(clk_sys),.d(busy),.q(cache_ack));
    assign ready=disc_ready && !cpu_trap;
    assign diagnostic=cpu_trap ? 32'hffff0008 : progress;
    assign last_error=cd_error;

    // The helper's sector region is mirrored to a dual-clock BRAM. CPU
    // writes occur after APF finishes its writes; firmware cannot publish
    // the buffer again until the complete previous sector has streamed.
    wire host_sector=bridge_wr && bridge_addr[31:12]==20'h6001e && bridge_addr[11:2]<642;
    wire cpu_sector=cpu_write && cpu_addr[31:12]==20'h0001e && cpu_addr[11:2]<642;
    wire [9:0] sector_write_addr=host_sector ? bridge_addr[11:2] : cpu_addr[11:2];
    wire [31:0] sector_write_data=host_sector ? bridge_data : reverse_bytes(cpu_data);
    wire [3:0] sector_byte_enable=host_sector ? 4'hf :
        {cpu_strobes[0],cpu_strobes[1],cpu_strobes[2],cpu_strobes[3]};
    reg [10:0] index=0;
    wire [31:0] sector_q;
    altsyncram #(.operation_mode("DUAL_PORT"),
        .intended_device_family("Cyclone V"),.width_a(32),.width_b(32),
        .widthad_a(10),.widthad_b(10),.numwords_a(1024),.numwords_b(1024),
        .width_byteena_a(4),.byte_size(8),.address_reg_b("CLOCK1"),
        .outdata_reg_b("UNREGISTERED"),.read_during_write_mode_mixed_ports("DONT_CARE"),
        .power_up_uninitialized("FALSE"),.lpm_type("altsyncram")) sector_ram (
        .clock0(clk_bridge),.clock1(clk_sys),.address_a(sector_write_addr),
        .address_b(index[10:1]),.data_a(sector_write_data),.data_b(32'b0),
        .wren_a(host_sector || cpu_sector),.wren_b(1'b0),.byteena_a(sector_byte_enable),
        .byteena_b(1'b1),.q_a(),.q_b(sector_q),.rden_a(1'b1),.rden_b(1'b1),
        .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus()
    );
    wire ready_sys;
    pocket_sync ready_sync(.clk(clk_sys),.d(ready_toggle),.q(ready_sys));
    reg [2:0] pace=0;
    reg streaming=0;
    always @(posedge clk_sys) begin
        cache_valid<=0;
        if(reset) begin index<=0;pace<=0;streaming<=0;stream_done<=0;end
        else if(ready_sys!=stream_done && !streaming) begin index<=0;pace<=0;streaming<=1;end
        else if(streaming) begin
            pace<=pace+1'b1;
            if(pace==7) begin
                cache_data<=index[0] ? sector_q[15:0] : sector_q[31:16];cache_valid<=1;
                if(index==1283) begin streaming<=0;stream_done<=ready_sys;end
                else index<=index+1'b1;
            end
        end
    end

    always @(posedge clk_bridge) begin
        cpu_ready<=0;
        if(grant) request<=0;
        if(done) begin io_busy<=0;io_done<=1;io_error<=error;end
        if(cpu_access) begin
            memory_phase<=1;
            if(cpu_addr[31:12]==20'h80000 && cpu_addr[11:8]==0 && |cpu_strobes) begin
                case(cpu_addr[7:0])
                    8'h04: slot<=cpu_data[15:0];
                    8'h08: file_offset<=cpu_data;
                    8'h0c: buffer_address<=cpu_data;
                    8'h10: length<=cpu_data;
                    8'h14: if(!io_busy) begin
                        operation<=cpu_data[1:0];request<=1;io_busy<=1;io_done<=0;io_error<=0;
                    end
                    8'h20: disc_ready<=cpu_data[0];
                    8'h24: progress<=cpu_data;
                    8'h38: if(pending && cpu_data[31:8]==token) begin
                        pending<=0;cd_error<=cpu_data[2:0];
                        if(cpu_data[7:0]==0) begin ready_toggle<=!ready_toggle;cd_state<=2;end
                        else cd_state<=4;
                    end
                    default: ;
                endcase
            end
        end else if(memory_phase==1) memory_phase<=2;
        else if(memory_phase==2) begin
            cpu_result<=0;
            if(cpu_ram) cpu_result<=ram_q_a;
            else if(cpu_addr[31:8]==24'h800001) cpu_result<=datatable_q;
            else if(cpu_addr[31:8]==24'h800000) case(cpu_addr[7:0])
                8'h00: cpu_result<={31'b0,assets_complete};
                8'h18: cpu_result<={21'b0,io_error,6'b0,io_done,io_busy};
                8'h20: cpu_result<={31'b0,disc_ready};
                8'h24: cpu_result<=diagnostic;
                8'h28: cpu_result<=cue_size;
                8'h2c: cpu_result<={30'b0,busy,pending};
                8'h30: cpu_result<=requested_lba;
                8'h34: cpu_result<={8'b0,token};
                default: ;
            endcase
            cpu_ready<=1;memory_phase<=3;
        end else if(memory_phase==3) memory_phase<=0;

        case(cd_state)
            0: if(req_host && ready && !reset_host) begin
                requested_lba<=cache_lba;token<=token+1'b1;
                pending<=1;busy<=1;cd_error<=0;cd_state<=1;
            end
            2: if(done_host==ready_toggle) begin busy<=0;cd_state<=3;end
            3: if(!req_host) cd_state<=0;
            // A failed sector never reaches the cache. Retry after reset.
            4: ;
            default: ;
        endcase
        if(reset_host && cd_state!=0) begin
            pending<=0;token<=token+1'b1;
            // An already published sector must drain before reuse of its RAM.
            if(cd_state==2) begin
                if(done_host==ready_toggle) begin busy<=0;cd_state<=0;end
            end else begin busy<=0;cd_state<=0;end
        end
        if(reset) begin
            cpu_ready<=0;memory_phase<=0;request<=0;io_busy<=0;io_done<=0;io_error<=0;
            disc_ready<=0;progress<=0;pending<=0;busy<=0;token<=0;cd_state<=0;
            ready_toggle<=0;cd_error<=0;
        end
    end
endmodule
