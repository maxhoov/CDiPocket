`timescale 1ns/1ps
`include "bus.svh"
module tb_servo;
    reg clk=0,reset=1,mounted=0,mount=0,audio=0;
    always #16.666667 clk=~clk;
    parallel_spi spi();
    wire closed,fault;
    servo_hle servo(.clk,.reset,.spi,.quirk_force_mode_fault(fault),
        .audio_cd_in_tray(audio),.cd_img_mount(mount),.cd_img_mounted(mounted),
        .tray_is_closed(closed));

    task automatic transfer(input [7:0] value, input [7:0] expected);
        @(negedge clk);spi.mosi=value;spi.write=1;
        #1;
        if(spi.miso!==expected) $fatal(1,"Servo response to %h: %h expected %h",value,spi.miso,expected);
        @(negedge clk);spi.write=0;
    endtask

    task automatic status(input [7:0] expected);
        transfer(8'hb0,8'h55);
        transfer(8'h00,8'h61);
        transfer(8'h00,8'h01);
        transfer(8'h00,8'h01);
        repeat(85) @(posedge clk);
        transfer(8'haa,8'h03);
        transfer(8'haa,8'hb0);
        transfer(8'haa,8'h00);
        transfer(8'haa,expected);
        transfer(8'haa,8'h25);
        repeat(85) @(posedge clk);
    endtask

    initial begin
        spi.write=0;spi.mosi=0;
        repeat(5) @(posedge clk);
        // Mount completes during reset, as with APF startup data slots.
        @(negedge clk);mounted=1;mount=1;
        @(negedge clk);mount=0;
        repeat(5) @(posedge clk);
        @(negedge clk);reset=0;
        status(8'h04);
        if(!closed) $fatal(1,"Mounted startup disc has an open tray");
        $display("PASS startup disc survives a mount edge during reset");
        @(negedge clk);reset=1;
        repeat(5) @(posedge clk);
        @(negedge clk);reset=0;
        status(8'h04);
        $display("PASS machine reset retains the mounted disc");
        @(negedge clk);reset=1;mounted=0;
        repeat(5) @(posedge clk);
        @(negedge clk);reset=0;
        status(8'h03);
        $display("PASS no disc is reported when no image is mounted");
        $display("ALL SERVO TESTS PASSED");$finish;
    end
    initial begin #1000000;$fatal(1,"Servo test timed out");end
endmodule
