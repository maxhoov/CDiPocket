// ROM bridge queue, power-up RAM clear and MCD212 SDRAM ownership.
module pocket_memory #(parameter RAM_BYTES=1048576) (
    input clk, input reset, input core_reset, input paused,
    input [63:0] loader_data, input loader_empty, output reg loader_pop=0,
    output reg accepting=0, output reg ready=0, output idle,
    output reg [12:0] slave_addr=0, output reg [7:0] slave_data=0,
    output reg slave_wr=0,
    input [24:0] cdi_addr, input [15:0] cdi_din,
    input cdi_rd,input cdi_wr,input cdi_word,input cdi_burst,input cdi_refresh,
    output reg [24:0] addr=0, output reg [15:0] din=0,
    output reg rd=0,output reg wr=0,output reg word=1,
    output reg burst=0,output reg refresh=0,input busy
);
    reg [3:0] state=0;
    reg [19:0] clear_addr=0;
    reg [13:0] wait_count=0;
    reg [31:0] load_addr=0,load_data=0;
    reg [1:0] byte_index=0;
    reg busy_q=0;
    reg [7:0] refresh_count=0;
    assign idle=ready && loader_empty && state==0;
    always @* begin
        addr=cdi_addr; din=cdi_din; rd=cdi_rd; wr=cdi_wr;
        word=cdi_word; burst=cdi_burst; refresh=cdi_refresh;
        if(core_reset || paused || !ready || state!=0) begin
            addr=0;din=0;rd=0;wr=0;word=1;burst=0;refresh=0;
            if(state==2) begin
                addr={5'b0,clear_addr};
                wr=!busy && loader_empty && refresh_count<200;
            end
            if(state==11) begin refresh=1;rd=!busy;end
            if(state==5 || state==7) begin
                addr=25'h0400000+{6'b0,load_addr[18:0]}+(state==7 ? 2 : 0);
                din=state==7 ? load_data[15:0] : load_data[31:16]; wr=!busy;
            end
            if(state==0 && ready && loader_empty) begin refresh=1;rd=!busy && !busy_q;end
        end
    end
    always @(posedge clk) begin
        loader_pop<=0; slave_wr<=0; busy_q<=busy;
        if(refresh_count<200) refresh_count<=refresh_count+1'b1;
        if(state==11 && busy) refresh_count<=0;
        if(reset) begin
            state<=1;clear_addr<=0;wait_count<=0;accepting<=0;ready<=0;refresh_count<=0;
        end
        else case(state)
            // APF may load assets after this short physical initialization.
            // Clearing the emulated RAM continues during Setup, with the
            // emulated CPU still held in reset until ready is asserted.
            1: if(wait_count==14999) begin accepting<=1;state<=2;end
                else wait_count<=wait_count+1'b1;
            2: if(busy) state<=3;
               else if(refresh_count==200) state<=11;
               else if(!loader_empty) begin
                   load_addr<=loader_data[63:32];load_data<=loader_data[31:0];
                   loader_pop<=1;state<=4;
               end
            3: if(busy_q && !busy) begin
                if(clear_addr==RAM_BYTES-2) begin ready<=1;state<=0;end
                else begin clear_addr<=clear_addr+2;state<=2;end
            end
            0: if(!loader_empty && !busy) begin
                load_addr<=loader_data[63:32];load_data<=loader_data[31:0];
                loader_pop<=1;state<=4;
            end
            4: if(load_addr[31:28]==1) state<=5;
                else begin byte_index<=0;state<=9;end
            5: if(busy) state<=6;
            6: if(busy_q && !busy) state<=7;
            7: if(busy) state<=8;
            8: if(busy_q && !busy) state<=ready ? 0 : 2;
            9: begin
                slave_addr<=load_addr[12:0]+byte_index;
                slave_data<=load_data[31-byte_index*8 -: 8]; slave_wr<=1;
                if(byte_index==3) state<=10;
                else byte_index<=byte_index+1'b1;
            end
            10: state<=ready ? 0 : 2;
            11: if(busy) state<=12;
            12: if(busy_q && !busy) state<=2;
            default: state<=0;
        endcase
    end
endmodule
