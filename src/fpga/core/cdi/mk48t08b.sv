`include "bus.svh"

module mk48t08b (
    // CPU interface
    input             clk,
    input             reset,
    input      [12:0] cpu_address,   // 8192 byte of RAM
    input      [ 7:0] cpu_din,
    output bit [ 7:0] cpu_dout,
    input             cs,
    input             write_strobe,
    output bit        bus_ack,

    // HPS interface
    input [12:0] nvram_backup_restore_adr,
    input nvram_bridge_clk,
    input [31:0] nvram_restore_data,
    output [31:0] nvram_backup_data,
    input nvram_restore_write,
    output bit nvram_cpu_changed,
    input nvram_allow_cpu_access,

    // RTC MSM6242B
    input [64:0] hps_rtc
);
    localparam bit [12:0] kYearAdr = 13'h1fff;
    localparam bit [12:0] kMonthAdr = 13'h1ffe;
    localparam bit [12:0] kDateAdr = 13'h1ffd;
    localparam bit [12:0] kDayAdr = 13'h1ffc;
    localparam bit [12:0] kHoursAdr = 13'h1ffb;
    localparam bit [12:0] kMinutesAdr = 13'h1ffa;
    localparam bit [12:0] kSecondsAdr = 13'h1ff9;
    localparam bit [12:0] kControlAdr = 13'h1ff8;

    bit nvram_read_bus_ack;
    // 8 kB of NVRAM
    wire [7:0] nvram_readout;

    // hps_rtc is constant and only set at core start
    // The OS of the CD-i only reads the time once and keeps track of time itself afterwards
    // No need to calculate a wall clock here
    always_comb begin
        case (cpu_address)
            kYearAdr: begin
                cpu_dout = hps_rtc[47:40];  // BCD Year 00-99

                // There is a special case to catch here
                // A MiSTer without internet or RTC will start at the year 1970
                // This is detected by the CD-i OS as 2070 which doesn't makes any sense
                // If xx70 is detected, we will correct that to xx94
                if (cpu_dout == 8'h70) cpu_dout = 8'h94;
            end
            kMonthAdr: cpu_dout = hps_rtc[39:32];  // BCD Month 01-12
            kDateAdr: cpu_dout = hps_rtc[31:24];  // BCD Day of the month 01-31
            // According to the datasheet of the MSM6242B, the Day of week is 00-06
            // We increment by 1 to adapt it to the expected format
            kDayAdr: cpu_dout = hps_rtc[55:48] + 1;  // BCD Day of the week 01-07
            kHoursAdr: cpu_dout = hps_rtc[23:16];  // BCD Hours 00-23
            kMinutesAdr: cpu_dout = hps_rtc[15:8];  // BCD Minutes 00-59
            kSecondsAdr: cpu_dout = hps_rtc[7:0];  // BCD Seconds 00-59
            kControlAdr: begin
                // Just use RAM
                cpu_dout = nvram_readout;
            end
            default: cpu_dout = nvram_readout;
        endcase
    end

    always_ff @(posedge clk) begin
        // access to time keeper registers don't count as NvRAM change
        nvram_cpu_changed <= !reset && nvram_cpu_side_write && cpu_address < kControlAdr;

        // nvram_readout takes one cycle, apply that to the bus_ack only during read.
        // only provide an ack if it wasn't given last cycle
        nvram_read_bus_ack <= (!reset && cs && !write_strobe && !nvram_read_bus_ack && nvram_allow_cpu_access);

        if (nvram_cpu_side_write && bus_ack) $display("NVRAM Written %x %x", cpu_address, cpu_din);
    end

    wire nvram_cpu_side_write = !reset && cs && write_strobe && nvram_allow_cpu_access;
    assign bus_ack = nvram_read_bus_ack || (write_strobe && nvram_allow_cpu_access);


    pocket_byte_ram nvram (
        .clk_a(clk),
        .clk_b(nvram_bridge_clk),

        // CPU side interface
        .data_a(cpu_din),
        .addr_a(cpu_address),
        .we_a(nvram_cpu_side_write),
        .q_a(nvram_readout),

        // HPS Backup/Restore side interface
        .data_b(nvram_restore_data),
        .addr_b(nvram_backup_restore_adr[12:2]),
        .we_b(nvram_restore_write),
        .q_b(nvram_backup_data)
    );

endmodule
