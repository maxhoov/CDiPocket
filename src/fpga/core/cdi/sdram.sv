// verilator lint_off CASEINCOMPLETE
// verilator lint_off CASEX

//
// sdram.v
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram (

    // interface to the MT48LC16M16 chip
`ifdef VERILATOR
    input  reg [15:0] SDRAM_DQ_in,   // 16 bit bidirectional data bus
    output reg [15:0] SDRAM_DQ_out,  // 16 bit bidirectional data bus
`else
    inout wire [15:0] SDRAM_DQ,      // 16 bit bidirectional data bus
`endif
    output reg [12:0] SDRAM_A,       // 13 bit multiplexed address bus
    output reg        SDRAM_DQML,    // byte mask
    output reg        SDRAM_DQMH,    // byte mask
    output reg [ 1:0] SDRAM_BA,      // two banks
    output            SDRAM_nCS,     // a single chip select
    output reg        SDRAM_nWE,     // write enable
    output reg        SDRAM_nRAS,    // row address select
    output reg        SDRAM_nCAS,    // columns address select
    output            SDRAM_CLK,
    output            SDRAM_CKE,

    // cpu/chipset interface
    input init,  // init signal after FPGA config to initialize RAM
    input clk,   // sdram is accessed at up to 128MHz

    input      [24:0] addr,
    input             rd,
    input             wr,
    input             word,
    input             burst,
    input             refresh,
    output reg        burstdata_valid = 0,
    input      [15:0] din,
    output     [15:0] dout,
    output reg        busy = 0
);

    assign SDRAM_nCS = 0;
    assign SDRAM_CKE = 1;
`ifndef VERILATOR
    reg [15:0] dq_out;
    reg dq_oe = 0;
    assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
`endif


    localparam RASCAS_DELAY = 3'd1;  // tRCD=20ns -> 2 cycles@85MHz
    localparam BURST_LENGTH = 3'd2;  // 0=1, 1=2, 2=4, 3=8, 7=full page
    localparam ACCESS_TYPE = 1'd0;  // 0=sequential, 1=interleaved
    localparam CAS_LATENCY = 3'd2;  // 2/3 allowed
    localparam OP_MODE = 2'd0;  // only 0 (standard operation) allowed
    localparam NO_WRITE_BURST = 1'd1;  // 0=write burst enabled, 1=only single access write

    localparam MODE = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

    localparam STATE_IDLE = 4'd0;  // state to check the requests
    localparam STATE_START = STATE_IDLE + 1'd1;  // state in which a new command is started
    localparam STATE_CONT = STATE_START + RASCAS_DELAY;
    localparam STATE_READY = STATE_CONT + CAS_LATENCY;
    localparam STATE_LAST = STATE_READY;  // last state in cycle

    reg  [ 3:0] state = STATE_IDLE;
    reg  [24:0] a;  // temporary storage of address to allow change after request
    reg  [15:0] data;
    reg         we;  // temporary storage of wr to allow change after request
    reg         ds;  // temporary storage of word to allow change after request
    reg         ram_req = 0;
    wire        ram_req_test = !refresh;
    reg  [15:0] last_data;
    // Unconditional input sampling allows the fitter to use the I/O
    // register at each DQ pin. Consumers latch only on busy/valid events.
    always_ff @(posedge clk) begin
`ifdef VERILATOR
        last_data <= SDRAM_DQ_in;
`else
        last_data <= SDRAM_DQ;
`endif
    end

    localparam MODE_NORMAL = 2'b00;
    localparam MODE_RESET = 2'b01;
    localparam MODE_LDM = 2'b10;
    localparam MODE_PRE = 2'b11;
    reg [1:0] mode = MODE_RESET;
    reg [4:0] reset = '1;

    reg [12:0] powerup_wait = 6000; // 200 us at 30 MHz
    reg old_rd = 0, old_wr = 0;
    // access manager
    always_ff @(posedge clk) begin
        old_rd <= old_rd & rd;
        old_wr <= old_wr & wr;

        if (state == STATE_IDLE && mode == MODE_NORMAL && powerup_wait == 0) begin
            burstdata_valid <= 0;

            if ((~old_rd & rd) | (~old_wr & wr)) begin
                old_rd <= rd;
                old_wr <= wr;
                we <= wr;
                ds <= word;
                busy <= 1;
                state <= STATE_START;
            end
        end

        if (state == STATE_START && busy) begin
            a <= addr;
            data <= word ? din : {din[7:0], din[7:0]};
            ram_req <= ram_req_test;
        end

        if (!burst && state == STATE_READY && busy) begin
            ram_req <= 0;
            we <= 0;
            busy <= 0;
            if (ram_req) begin
                if (we) begin
                    a <= '1;
                end
            end
        end

        if (state == STATE_READY + 3 && busy) begin
            ram_req <= 0;
            we <= 0;
            busy <= 0;
            if (ram_req) begin
                if (we) begin
                    a <= '1;
                end
            end
        end


        if (state >= STATE_READY && busy) begin
            burstdata_valid <= burst;

        end

        if (mode != MODE_NORMAL || state != STATE_IDLE || reset != 0) begin
            state <= state + 1'd1;
            if (!burst && state == STATE_LAST) state <= STATE_IDLE;
            if (state == STATE_LAST + 3) state <= STATE_IDLE;
        end
    end

    assign dout = ((~ds & a[0]) ? {last_data[7:0], last_data[15:8]} : last_data);

    // initialization 
    reg init_old = 0;
    always_ff @(posedge clk) begin
        init_old <= init;
        if (init) powerup_wait <= 6000;
        else if (powerup_wait != 0) powerup_wait <= powerup_wait - 1;

        if (init_old & ~init) reset <= '1;
        else if (state == STATE_LAST && powerup_wait == 0) begin
            if (reset != 0) begin
                reset <= reset - 5'd1;
                if (reset == 14) mode <= MODE_PRE;
                else if (reset == 3) mode <= MODE_LDM;
                else mode <= MODE_RESET;
            end else mode <= MODE_NORMAL;
        end
    end

    localparam CMD_NOP = 3'b111;
    localparam CMD_ACTIVE = 3'b011;
    localparam CMD_READ = 3'b101;
    localparam CMD_WRITE = 3'b100;
    localparam CMD_BURST_TERMINATE = 3'b110;
    localparam CMD_PRECHARGE = 3'b010;
    localparam CMD_AUTO_REFRESH = 3'b001;
    localparam CMD_LOAD_MODE = 3'b000;

    wire [1:0] dqm = {we & ~ds & ~a[0], we & ~ds & a[0]};

    // SDRAM state machines
    always_ff @(posedge clk) begin
        {SDRAM_DQMH, SDRAM_DQML} <= 2'b00;
        if (state == STATE_CONT && mode == MODE_NORMAL && ram_req) {SDRAM_DQMH, SDRAM_DQML} <= dqm;
        if (state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? {1'b0, addr[24]} : 2'b00;

`ifndef VERILATOR
        dq_oe <= 0;
`endif

        casex ({
            ram_req, we, mode, state
        })
            // verilog_format: off
            {2'bXX, MODE_NORMAL, STATE_START} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= ram_req_test ? CMD_ACTIVE : CMD_AUTO_REFRESH;
`ifdef VERILATOR
            {2'b11, MODE_NORMAL, STATE_CONT} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_DQ_out} <= {CMD_WRITE, data};
`else
            {2'b11, MODE_NORMAL, STATE_CONT} : begin
                {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, dq_out} <= {CMD_WRITE, data};
                dq_oe <= 1;
            end
`endif
            {2'b10, MODE_NORMAL, STATE_CONT} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

            // init
            {2'bXX, MODE_LDM, STATE_START} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
            {2'bXX, MODE_PRE, STATE_START} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

            default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
            // verilog_format: on
        endcase

        if (powerup_wait != 0) begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
            SDRAM_A <= 0;
        end else if (mode == MODE_NORMAL) begin
            casex (state)
                // apply row address
                STATE_START: SDRAM_A <= addr[23:11];
                // apply column address
                STATE_CONT:  SDRAM_A <= {2'b00, 1'b1, a[10:1]};
            endcase

        end else if (mode == MODE_LDM && state == STATE_START) SDRAM_A <= MODE;
        else if (mode == MODE_PRE && state == STATE_START) SDRAM_A <= 13'b0010000000000;
        else SDRAM_A <= 0;
    end

`ifndef VERILATOR

    altddio_out #(
        .extend_oe_disable("OFF"),
        .intended_device_family("Cyclone V"),
        .invert_output("OFF"),
        .lpm_hint("UNUSED"),
        .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"),
        .width(1)
    ) sdramclk_ddr (
        .datain_h(1'b0),
        .datain_l(1'b1),
        .outclock(clk),
        .dataout(SDRAM_CLK),
        .aclr(1'b0),
        .aset(1'b0),
        .oe(1'b1),
        .outclocken(1'b1),
        .sclr(1'b0),
        .sset(1'b0)
    );

`endif

endmodule
