
module servo_hle (
    input clk,
    input reset,
    parallel_spi.slave spi,
    output bit quirk_force_mode_fault,
    input audio_cd_in_tray,
    input cd_img_mount,
    input cd_img_mounted,
    output tray_is_closed
);

    enum bit [6:0] {
        IDLE,
        PROVIDE_B0_0,
        PROVIDE_B0_1,
        PROVIDE_B0_2,
        PROVIDE_B0_3,
        PROVIDE_B0_10,
        PROVIDE_B0_11,
        PROVIDE_B0_12,
        PROVIDE_B0_13,
        PROVIDE_B0_14,
        PROVIDE_B0_15
    } com_state = IDLE;

    enum bit [1:0] {
        NO_DISC,
        CDI,
        AUDIO
    } disc_state = NO_DISC;

    enum bit [1:0] {
        CLOSED,
        OPEN
    } tray_state = CLOSED;

    assign tray_is_closed = tray_state == CLOSED;

    // Some measurements from a 210/05
    // A closed tray with Audio CD is B0 00 01 25
    // A closed tray with no disc is B0 00 03 25
    // A closed tray with Robocop is B0 00 04 25
    // A closed tray with Tetris is B0 00 04 25
    // cdiemu seems to use B0 00 02 25, which
    // seems to work alright for a CD-i title.
    // But the detection of VCDs is not performed with that Disc state
    bit [15:0] b0_result;  // Disc State Word

    always_comb begin
        b0_result = 0;

        case (disc_state)
            CDI: b0_result[15:8] = 8'h04;
            AUDIO: b0_result[15:8] = 8'h01;
            default: b0_result[15:8] = 8'h03;
        endcase

        case (tray_state)
            CLOSED: b0_result[7:0] = 8'h25;
            OPEN: b0_result[7:0] = 8'h21;
            default: b0_result[7:0] = 8'h25;
        endcase
    end

    bit [14:0] mode_fault_cnt = 0;
    bit [14:0] perform_mode_fault;

    always_comb begin
        spi.miso = 8'hff;
        perform_mode_fault = 0;

        if (com_state == IDLE && spi.write && spi.mosi == 8'hdd) begin
            // After some 0xff, the first requerst by SLAVE is 0xDD. We answer with 0xEE
            spi.miso = 8'hee;
        end

        // verilog_format: off
        if (com_state == IDLE && spi.write && spi.mosi == 8'ha6) begin spi.miso = 8'h55; perform_mode_fault = 80; end
        if (com_state == IDLE && spi.write && spi.mosi == 8'ha7) begin spi.miso = 8'h55; perform_mode_fault = 80; end
        if (com_state == IDLE && spi.write && spi.mosi == 8'hb0) begin spi.miso = 8'h55; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_0 && spi.write) begin spi.miso = 8'h61; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_1 && spi.write) begin spi.miso = 8'h01; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_2 && spi.write) begin spi.miso = 8'h01; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_3 && mode_fault_cnt==0) begin perform_mode_fault = 15'h2ff; end

        // MOSI 0xAA AA AA AA AA
        // MISO 0x03 B0 00 02 15 to fake closed try with CD-i inside
        if (com_state == PROVIDE_B0_10 && spi.write) begin spi.miso = 8'h03; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_11 && spi.write) begin spi.miso = 8'hB0; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_12 && spi.write) begin spi.miso = 8'h00; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_13 && spi.write) begin spi.miso = b0_result[15:8]; perform_mode_fault = 80; end
        if (com_state == PROVIDE_B0_14 && spi.write) begin spi.miso = b0_result[7:0]; perform_mode_fault = 80; end
        // verilog_format: on
        if (spi.write) $display("SERVO %x %x", spi.mosi, spi.miso);
    end

    always_ff @(posedge clk) begin

        if (reset) begin
            mode_fault_cnt <= 0;
            quirk_force_mode_fault <= 0;
            com_state <= IDLE;
            tray_state <= CLOSED;
            // Pocket chooses the disc before releasing the machine reset.
            // Its mount edge may already have passed while reset was active.
            if (cd_img_mounted) disc_state <= audio_cd_in_tray ? AUDIO : CDI;
            else disc_state <= NO_DISC;
        end else begin
            if (perform_mode_fault != 0) begin
                mode_fault_cnt <= perform_mode_fault;
            end else if (mode_fault_cnt != 0) begin
                mode_fault_cnt <= mode_fault_cnt - 1;
            end

            quirk_force_mode_fault <= mode_fault_cnt == 1;

            case (com_state)
                IDLE: begin
                    if (spi.write) begin
                        case (spi.mosi)
                            8'hb0: begin  // Request disc status
                                com_state <= PROVIDE_B0_0;
                                $display("SERVO was asked B0");
                            end
                            8'ha6: begin  // Open the tray
                                tray_state <= OPEN;
                                disc_state <= NO_DISC;
                                com_state  <= PROVIDE_B0_0;
                            end
                            8'ha7: begin  // Close the tray
                                tray_state <= CLOSED;
                                if (cd_img_mounted) disc_state <= audio_cd_in_tray ? AUDIO : CDI;
                                else disc_state <= NO_DISC;
                                com_state <= PROVIDE_B0_0;
                            end
                            default: begin
                                // What to do here?
                            end
                        endcase
                    end

                    if (cd_img_mount) begin
                        disc_state <= audio_cd_in_tray ? AUDIO : CDI;
                        com_state <= PROVIDE_B0_10;
                        tray_state <= CLOSED;
                        quirk_force_mode_fault <= 1;
                        $display("Update of disc state");
                    end

                end

                // MOSI 0xB0 00 00 00
                // MISO 0x55 61 01 01
                PROVIDE_B0_0: if (spi.write) com_state <= PROVIDE_B0_1;
                PROVIDE_B0_1: if (spi.write) com_state <= PROVIDE_B0_2;
                PROVIDE_B0_2: if (spi.write) com_state <= PROVIDE_B0_3;
                PROVIDE_B0_3: if (mode_fault_cnt == 0) com_state <= PROVIDE_B0_10;

                // MOSI 0xAA AA AA AA AA
                // MISO 0x03 B0 00 02 15 to fake closed try with CD-i inside
                PROVIDE_B0_10: if (spi.write) com_state <= PROVIDE_B0_11;
                PROVIDE_B0_11: if (spi.write) com_state <= PROVIDE_B0_12;
                PROVIDE_B0_12: if (spi.write) com_state <= PROVIDE_B0_13;
                PROVIDE_B0_13: if (spi.write) com_state <= PROVIDE_B0_14;
                PROVIDE_B0_14: if (spi.write) com_state <= PROVIDE_B0_15;
                PROVIDE_B0_15: if (mode_fault_cnt == 0) com_state <= IDLE;

                default: begin
                end
            endcase
        end
    end

endmodule
