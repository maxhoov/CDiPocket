// SPDX-License-Identifier: GPL-3.0-or-later
// Framework startup precedes deferred file I/O. The emulated CPU remains
// reset until the files and machine memory have actually been initialized.
module pocket_startup (
    input clk,input reset,input reset_n,input loading,input assets_complete,
    input memory_accepting,input memory_idle,input slave_seen,input bios_seen,
    input disc_ready,input loader_overflow,
    output reg framework_ready=0,output files_enabled,output machine_ready
);
    always @(posedge clk) begin
        if(reset) framework_ready<=0;
        else if(assets_complete && memory_accepting && slave_seen && !loader_overflow)
            framework_ready<=1;
    end
    assign files_enabled=framework_ready && reset_n;
    assign machine_ready=framework_ready && assets_complete && !loading &&
        memory_idle && slave_seen && bios_seen && disc_ready && !loader_overflow;
endmodule

// One target command at a time: chunked BIOS, NVRAM save, or native disc.
// Shared by core_top and the complete framework/file-firmware startup test.
module pocket_file_io (
    input clk,input reset,input files_enabled,input memory_idle,
    input [31:0] bios_size,input nv_allowed,input nv_changed,input in_menu,
    input disc_request,input [1:0] disc_operation,input [15:0] disc_slot,
    input [31:0] disc_offset,disc_address,disc_length,
    output reg disc_grant=0,disc_done=0,output reg [2:0] disc_error=0,
    input target_ack,target_done,input [2:0] target_error,
    output reg target_read=0,target_write=0,target_getfile=0,target_openfile=0,
    output reg [15:0] target_id=0,
    output reg [31:0] target_offset=0,target_address=0,target_length=0,
    output reg bios_seen=0,nv_save_freeze=0,
    output reg [2:0] save_error=0,boot_error=0
);
    reg dirty=0,save_pending=0,menu_q=0;
    reg [3:0] state=0;
    reg [18:0] bios_offset=0;
    reg [5:0] drain_settle=0;
    always @(posedge clk) begin
        target_read<=0;target_write<=0;target_getfile<=0;target_openfile<=0;
        disc_grant<=0;disc_done<=0;menu_q<=in_menu;
        if(nv_changed) dirty<=1;
        if(in_menu && !menu_q && dirty) save_pending<=1;
        case(state)
            // Before Reset Exit, leave the target register free for 0140.
            0: if(files_enabled) begin
                if(!bios_seen && bios_size==524288 && memory_idle) begin
                    target_id<=1;target_offset<={13'b0,bios_offset};
                    target_address<=32'h10000000+{13'b0,bios_offset};
                    target_length<=4096;target_read<=1;state<=6;
                end else if(save_pending) begin nv_save_freeze<=1;state<=3;end
                else if(disc_request) begin
                    target_id<=disc_slot;target_offset<=disc_offset;target_address<=disc_address;
                    target_length<=disc_length;
                    case(disc_operation)
                        1: target_read<=1;
                        2: target_getfile<=1;
                        3: target_openfile<=1;
                        default: ;
                    endcase
                    disc_grant<=1;state<=1;
                end
            end
            1: if(target_ack) state<=2;
            2: if(target_done) begin disc_done<=1;disc_error<=target_error;state<=0;end
            3: if(!nv_allowed) begin
                target_id<=3;target_offset<=0;target_address<=32'h40000000;
                target_length<=8192;target_write<=1;state<=4;
            end
            4: if(target_ack) state<=5;
            5: if(target_done) begin
                save_error<=target_error;
                if(target_error==0) dirty<=0;
                save_pending<=0;nv_save_freeze<=0;state<=0;
            end
            6: if(target_ack) state<=7;
            7: if(target_done) begin
                boot_error<=target_error;drain_settle<=32;
                state<=target_error==0 ? 8 : 9;
            end
            // Drain each 4 KiB before accepting another BIOS chunk.
            8: if(drain_settle!=0) drain_settle<=drain_settle-1'b1;
               else if(memory_idle) begin
                   if(bios_offset==19'h7f000) bios_seen<=1;
                   else bios_offset<=bios_offset+19'd4096;
                   state<=0;
               end
            9: ; // I/O error: machine_ready stays low, preserving CPU reset.
            default: state<=0;
        endcase
        if(reset) begin
            state<=0;dirty<=0;save_pending<=0;menu_q<=0;bios_offset<=0;drain_settle<=0;
            bios_seen<=0;nv_save_freeze<=0;save_error<=0;boot_error<=0;disc_error<=0;
            disc_grant<=0;disc_done<=0;
            target_read<=0;target_write<=0;target_getfile<=0;target_openfile<=0;
            target_id<=0;target_offset<=0;target_address<=0;target_length<=0;
        end
    end
endmodule
