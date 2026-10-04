# APF's constraints already create input clocks and derive PLL clocks.
derive_clock_uncertainty
# Group related system PLL outputs together; reference/bridge and audio
# domains are asynchronous. Dedicated synchronizers/mailboxes cross them.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a}] \
    -group [get_clocks {clk_74b}] \
    -group [get_clocks {bridge_spiclk}] \
    -group [get_clocks {*pocket_clocks*sys*divclk*}] \
    -group [get_clocks {*pocket_clocks*audio*divclk*}]
# SDRAM uses the opposite-edge forwarded clock, CAS=2 at 30 MHz.
create_generated_clock -name dram_clock -source [get_pins {ic|pocket_clocks|sys|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -invert [get_ports dram_clk]
set_output_delay -clock dram_clock -max 2.0 [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke dram_dq[*]}]
set_output_delay -clock dram_clock -min -1.0 [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke dram_dq[*]}]
set_input_delay -clock dram_clock -max 6.0 [get_ports {dram_dq[*]}]
set_input_delay -clock dram_clock -min 2.0 [get_ports {dram_dq[*]}]
