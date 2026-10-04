// U3090MG Display Controller for the Front Display
// Information only based on philips_cdi_210.pdf, the service manual of the CDi 210
// Memory map not available, I2C protocol unknown
// TODO reverse engineer using real CDi 210 and logic analyzer

module u3090mg (
    input clk,

    input sda_in,
    output bit sda_out,
    input scl
);

    localparam bit [6:0] SLAVE_ADR = 7'h38;

    bit [7:0] ram[16];

    enum bit [3:0] {
        IDLE,
        DEVICE_ADR,
        READ,
        WRITE
    } state;

    bit [7:0] shiftreg;
    bit [3:0] cnt = 0;

    wire sda = sda_out && sda_in;

    bit sda_q;
    bit scl_q;

    always_ff @(posedge clk) begin
        sda_q <= sda;
        scl_q <= scl;

        if (scl && scl_q && sda && !sda_q) begin
            // Stop condition
            state <= IDLE;
            cnt <= 0;
            sda_out <= 1;
        end else begin
            case (state)
                IDLE: begin
                    sda_out <= 1;
                    cnt <= 0;

                    if (scl && scl_q && !sda && sda_q) state <= DEVICE_ADR;
                end
                DEVICE_ADR: begin
                    if (scl && !scl_q) begin
                        cnt <= cnt + 1;

                        if (cnt <= 7) shiftreg[7:0] <= {shiftreg[6:0], sda_in};
                    end

                    if (!scl && scl_q && cnt == 8) begin
                        // $display("-- I2C Adr %x rw %d", shiftreg[7:1], shiftreg[0]);

                        if (shiftreg[7:1] == SLAVE_ADR) begin
                            sda_out <= 0;  // ACK
                        end else state <= IDLE;
                    end

                    if (!scl && scl_q && cnt == 9) begin
                        sda_out <= 1;  // ACK off
                        state <= shiftreg[0] ? READ : WRITE;

                        shiftreg <= 8'hff;
                        // $display("-- I2C DATA %x rw %d", shiftreg[7:1]);

                        cnt <= 0;
                    end
                end
                READ: begin
                    sda_out <= shiftreg[7];

                    if (!scl && scl_q) begin
                        cnt <= cnt + 1;
                        if (cnt <= 8) shiftreg[7:0] <= {shiftreg[6:0], 1'b1};
                    end

                    if (!scl && scl_q && cnt == 8) begin
                        // $display("-- I2C DATA %x rw %d", shiftreg[7:1], shiftreg[0]);
                        cnt <= 0;
                        shiftreg <= 8'hff;
                    end
                end
                WRITE: begin
                    if (scl && !scl_q) begin
                        cnt <= cnt + 1;

                        if (cnt <= 7) shiftreg[7:0] <= {shiftreg[6:0], sda_in};
                    end

                    if (!scl && scl_q && cnt == 8) begin
                        // $display("-- I2C DATA Write %x", shiftreg[7:0]);
                        sda_out <= 0;  // ACK
                    end

                    if (!scl && scl_q && cnt == 9) begin
                        sda_out <= 1;  // ACK off
                        shiftreg <= 0;
                        cnt <= 0;
                    end
                end
                default: begin
                end

            endcase
        end
    end

endmodule
