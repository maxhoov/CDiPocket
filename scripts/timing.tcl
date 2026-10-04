package require ::quartus::sta
project_open ap_core
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir ../../build/reports
report_clocks -file ../../build/reports/clocks.rpt
report_clock_transfers -file ../../build/reports/clock_transfers.rpt
report_timing -setup -npaths 10 -detail full_path -file ../../build/reports/setup.rpt
report_timing -hold -npaths 10 -detail full_path -file ../../build/reports/hold.rpt
report_ucp -file ../../build/reports/unconstrained.rpt
delete_timing_netlist
project_close
