//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`include "cdi/bus.svh"
`include "cdi/videotypes.svh"
`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;


assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;


assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;



wire clk_sys,clk_sys_90,clk_audio,pll_locked,pll_locked_host;
pocket_pll pocket_clocks(.refclk(clk_74a),.clk30(clk_sys),.clk30_90(clk_sys_90),
    .audio_clk(clk_audio),.locked(pll_locked));
pocket_sync lock_sync(.clk(clk_74a),.d(pll_locked),.q(pll_locked_host));
wire platform_reset,core_reset;
wire reset_n;
pocket_reset power_reset(.clk(clk_sys),.release_n(pll_locked),.reset(platform_reset));
wire memory_accepting,memory_accepting_host,memory_ready,memory_idle,memory_ready_host,memory_idle_host;
pocket_sync ma(.clk(clk_74a),.d(memory_accepting),.q(memory_accepting_host));
pocket_sync mr(.clk(clk_74a),.d(memory_ready),.q(memory_ready_host));
pocket_sync mi(.clk(clk_74a),.d(memory_idle),.q(memory_idle_host));
reg loading=0,assets_complete=0,slave_seen=0;
wire bios_seen;
reg [31:0] image_size=0;
reg [31:0] bios_size=0;
reg loader_overflow=0;
reg ntsc=0;
wire ntsc_sys;
pocket_sync tv(.clk(clk_sys),.d(ntsc),.q(ntsc_sys));
wire loader_full,loader_empty,loader_pop;
wire [63:0] loader_data;
wire asset_write=bridge_wr &&
    ((bridge_addr[31:19]==13'h200) || (bridge_addr[31:13]==19'h10000));
pocket_loader_fifo load_fifo(.wrclk(clk_74a),.rdclk(clk_sys),.reset(!pll_locked_host),
    .wr(asset_write && !loader_full),.rd(loader_pop),
    .data({bridge_addr,bridge_wr_data}),.q(loader_data),.full(loader_full),.empty(loader_empty));
wire disc_ready;
wire setup_done,files_enabled,machine_ready;
pocket_startup startup(.clk(clk_74a),.reset(!pll_locked_host),.reset_n(reset_n),
    .loading(loading),.assets_complete(assets_complete),.memory_accepting(memory_accepting_host),
    .memory_idle(memory_idle_host),.slave_seen(slave_seen),.bios_seen(bios_seen),
    .disc_ready(disc_ready),.loader_overflow(loader_overflow),
    .framework_ready(setup_done),.files_enabled(files_enabled),.machine_ready(machine_ready));
wire boot_done,running;
pocket_boot_status framework_status(.pll_locked(pll_locked_host),
    .memory_accepting(memory_accepting_host),.setup_done(setup_done),
    .reset_n(reset_n),.loading(loading),.boot_done(boot_done),.running(running));
pocket_reset machine_reset(.clk(clk_sys),
    .release_n(reset_n && pll_locked && machine_ready),.reset(core_reset));

wire [31:0] cmd_bridge_rd_data;
wire dataslot_requestread,dataslot_requestwrite,dataslot_update,dataslot_allcomplete;
wire [15:0] dataslot_requestread_id,dataslot_requestwrite_id,dataslot_update_id;
wire [31:0] dataslot_requestwrite_size,dataslot_update_size;
wire [31:0] rtc_epoch_seconds,rtc_date_bcd,rtc_time_bcd;
wire rtc_valid,osnotify_inmenu;
wire target_dataslot_ack,target_dataslot_done;
wire [2:0] target_dataslot_err;
wire target_read,target_write,target_getfile,target_openfile;
wire [15:0] target_id;
wire [31:0] target_offset,target_address,target_length;
wire [9:0] disc_datatable_addr;
wire [31:0] disc_datatable_q;
reg nv_host_freeze=0;
wire nv_save_freeze;
wire nv_allowed,nv_allowed_host;
pocket_sync na(.clk(clk_sys),.d(!(nv_host_freeze || nv_save_freeze)),.q(nv_allowed));
pocket_sync nb(.clk(clk_74a),.d(nv_allowed),.q(nv_allowed_host));
wire read_ack,read_ok,write_ack,write_ok;
pocket_slot_policy slot_policy(.memory_accepting(memory_accepting_host),.nv_allowed(nv_allowed_host),
    .read_id(dataslot_requestread_id),.write_id(dataslot_requestwrite_id),
    .write_size(dataslot_requestwrite_size),.read_ack(read_ack),.read_ok(read_ok),
    .write_ack(write_ack),.write_ok(write_ok));

core_bridge_cmd commands(
    .clk(clk_74a),.reset_n(reset_n),.bridge_endian_little(1'b0),
    .bridge_addr(bridge_addr),.bridge_rd(bridge_rd),.bridge_rd_data(cmd_bridge_rd_data),
    .bridge_wr(bridge_wr),.bridge_wr_data(bridge_wr_data),
    .status_boot_done(boot_done),.status_setup_done(setup_done),.status_running(running),
    .dataslot_requestread(dataslot_requestread),.dataslot_requestread_id(dataslot_requestread_id),
    .dataslot_requestread_ack(read_ack),.dataslot_requestread_ok(read_ok),
    .dataslot_requestwrite(dataslot_requestwrite),.dataslot_requestwrite_id(dataslot_requestwrite_id),
    .dataslot_requestwrite_size(dataslot_requestwrite_size),.dataslot_requestwrite_ack(write_ack),
    .dataslot_requestwrite_ok(write_ok),
    .dataslot_update(dataslot_update),.dataslot_update_id(dataslot_update_id),
    .dataslot_update_size(dataslot_update_size),.dataslot_allcomplete(dataslot_allcomplete),
    .rtc_epoch_seconds(rtc_epoch_seconds),.rtc_date_bcd(rtc_date_bcd),
    .rtc_time_bcd(rtc_time_bcd),.rtc_valid(rtc_valid),.osnotify_inmenu(osnotify_inmenu),
    .savestate_supported(1'b0),.savestate_addr(32'b0),.savestate_size(32'b0),
    .savestate_maxloadsize(32'b0),.savestate_start(),.savestate_start_ack(1'b0),
    .savestate_start_busy(1'b0),.savestate_start_ok(1'b0),.savestate_start_err(1'b0),
    .savestate_load(),.savestate_load_ack(1'b0),.savestate_load_busy(1'b0),
    .savestate_load_ok(1'b0),.savestate_load_err(1'b0),
    .target_dataslot_read(target_read),.target_dataslot_write(target_write),
    .target_dataslot_getfile(target_getfile),.target_dataslot_openfile(target_openfile),
    .target_dataslot_ack(target_dataslot_ack),.target_dataslot_done(target_dataslot_done),
    .target_dataslot_err(target_dataslot_err),.target_dataslot_id(target_id),
    .target_dataslot_slotoffset(target_offset),.target_dataslot_bridgeaddr(target_address),
    .target_dataslot_length(target_length),.target_buffer_param_struct(target_address),
    .target_buffer_resp_struct(target_address),.datatable_addr(disc_datatable_addr),.datatable_wren(1'b0),
    .datatable_data(32'b0),.datatable_q(disc_datatable_q)
);

always @(posedge clk_74a) begin
    if(asset_write && loader_full) loader_overflow<=1;
    if(bridge_wr && bridge_addr==32'h50000000) ntsc<=bridge_wr_data[0];
    if(bridge_wr && bridge_addr==32'hf8002004) image_size<=bridge_wr_data;
    if(bridge_wr && bridge_addr==32'hf800200c) bios_size<=bridge_wr_data;
    if(dataslot_update && dataslot_update_id==0) image_size<=dataslot_update_size;
    if(dataslot_requestwrite) begin
        loading<=1;assets_complete<=0;
        if(dataslot_requestwrite_id==0 && write_ok) image_size<=dataslot_requestwrite_size;
        if(dataslot_requestwrite_id==2) slave_seen<=dataslot_requestwrite_size==8192;
        if(dataslot_requestwrite_id==3) nv_host_freeze<=1;
    end
    if(dataslot_requestread && dataslot_requestread_id==3) nv_host_freeze<=1;
    if(dataslot_allcomplete) begin assets_complete<=1;loading<=0;nv_host_freeze<=0;end
end

wire [24:0] cdi_mem_addr,mem_addr;
wire [15:0] cdi_mem_din,mem_din,mem_dout;
wire cdi_mem_rd,cdi_mem_wr,cdi_mem_word,cdi_mem_burst,cdi_mem_refresh;
wire mem_rd,mem_wr,mem_word,mem_burst,mem_refresh,mem_busy,mem_valid;
wire clk_machine,machine_paused,audio_mute;
wire hs,vs,hblank,vblank_cdi,ce,field,interlaced;
pocket_pause menu_pause(.clk(clk_sys),.core_reset(core_reset),.in_menu(osnotify_inmenu),
    .vblank(vblank_cdi),.memory_idle(memory_idle),.memory_busy(mem_busy),.memory_valid(mem_valid),
    .cdi_rd(cdi_mem_rd),.cdi_wr(cdi_mem_wr),.clk_machine(clk_machine),
    .paused(machine_paused),.mute(audio_mute));
wire [12:0] slave_addr;
wire [7:0] slave_data;
wire slave_wr;
pocket_memory memory_control(.clk(clk_sys),.reset(platform_reset),.core_reset(core_reset),
    .paused(machine_paused),
    .loader_data(loader_data),.loader_empty(loader_empty),.loader_pop(loader_pop),
    .accepting(memory_accepting),.ready(memory_ready),.idle(memory_idle),.slave_addr(slave_addr),
    .slave_data(slave_data),.slave_wr(slave_wr),
    .cdi_addr(cdi_mem_addr),.cdi_din(cdi_mem_din),.cdi_rd(cdi_mem_rd),.cdi_wr(cdi_mem_wr),
    .cdi_word(cdi_mem_word),.cdi_burst(cdi_mem_burst),.cdi_refresh(cdi_mem_refresh),
    .addr(mem_addr),.din(mem_din),.rd(mem_rd),.wr(mem_wr),.word(mem_word),
    .burst(mem_burst),.refresh(mem_refresh),.busy(mem_busy));
sdram dram(.clk(clk_sys),.init(platform_reset),.addr(mem_addr),.din(mem_din),
    .dout(mem_dout),.rd(mem_rd),.wr(mem_wr),.word(mem_word),.burst(mem_burst),
    .refresh(mem_refresh),.busy(mem_busy),.burstdata_valid(mem_valid),
    .SDRAM_DQ(dram_dq),.SDRAM_A(dram_a),.SDRAM_BA(dram_ba),
    .SDRAM_DQML(dram_dqm[0]),.SDRAM_DQMH(dram_dqm[1]),.SDRAM_nCS(),
    .SDRAM_nWE(dram_we_n),.SDRAM_nRAS(dram_ras_n),.SDRAM_nCAS(dram_cas_n),
    .SDRAM_CLK(dram_clk),.SDRAM_CKE(dram_cke));

wire [31:0] seek_lba,cache_lba;
wire seek_valid,sector_tick,sector_delivered,stop_delivery;
wire [15:0] cd_data,cache_data;
wire cd_valid,cache_req,cache_ack,cache_valid;
wire disc_request;
wire [1:0] disc_operation;
wire [15:0] disc_slot;
wire [31:0] disc_offset,disc_address,disc_length,disc_bridge_data,disc_diagnostic;
wire disc_grant,disc_done;
wire [2:0] cd_error;
wire [2:0] cd_last_error;
wire mounted_host=disc_ready;
wire mounted_sys;
pocket_sync mount(.clk(clk_machine),.d(mounted_host),.q(mounted_sys));
reg mount_q=0;
always @(posedge clk_machine) mount_q<=mounted_sys;
hps_cd_sector_cache sector_cache(.clk(clk_machine),.reset(core_reset),
    .cd_hps_lba(cache_lba),.cd_hps_req(cache_req),.cd_hps_ack(cache_ack),
    .cd_hps_data_valid(cache_valid),.cd_hps_data(cache_data),
    .seek_lba(seek_lba),.seek_lba_valid(seek_valid),.cd_data(cd_data),.cd_data_valid(cd_valid),
    .sector_tick(sector_tick),.sector_delivered(sector_delivered),
    .stop_sector_delivery(stop_delivery),.config_disable_seek_time(1'b0));
pocket_native_disc disc_reader(.clk_bridge(clk_74a),.clk_sys(clk_machine),.reset(!pll_locked_host),
    .machine_reset(core_reset),.assets_complete(files_enabled),.cue_size(image_size),
    .bridge_addr(bridge_addr),.bridge_wr(bridge_wr),.bridge_data(bridge_wr_data),
    .bridge_q(disc_bridge_data),.ready(disc_ready),.diagnostic(disc_diagnostic),
    .datatable_addr(disc_datatable_addr),.datatable_q(disc_datatable_q),
    .cache_lba(cache_lba),.cache_req(cache_req),
    .cache_ack(cache_ack),.cache_data(cache_data),.cache_valid(cache_valid),
    .request(disc_request),.operation(disc_operation),.slot(disc_slot),
    .file_offset(disc_offset),.buffer_address(disc_address),.length(disc_length),
    .grant(disc_grant),.done(disc_done),
    .error(cd_error),.last_error(cd_last_error));

wire nv_changed,nv_changed_host;
flag_cross_domain nv_event(.clk_a(clk_machine),.clk_b(clk_74a),
    .flag_in_clk_a(nv_changed),.flag_out_clk_b(nv_changed_host));
wire [2:0] save_error,boot_error;
pocket_file_io file_io(.clk(clk_74a),.reset(!pll_locked_host),.files_enabled(files_enabled),
    .memory_idle(memory_idle_host),.bios_size(bios_size),.nv_allowed(nv_allowed_host),
    .nv_changed(nv_changed_host),.in_menu(osnotify_inmenu),
    .disc_request(disc_request),.disc_operation(disc_operation),.disc_slot(disc_slot),
    .disc_offset(disc_offset),.disc_address(disc_address),.disc_length(disc_length),
    .disc_grant(disc_grant),.disc_done(disc_done),.disc_error(cd_error),
    .target_ack(target_dataslot_ack),.target_done(target_dataslot_done),.target_error(target_dataslot_err),
    .target_read(target_read),.target_write(target_write),.target_getfile(target_getfile),
    .target_openfile(target_openfile),.target_id(target_id),.target_offset(target_offset),
    .target_address(target_address),.target_length(target_length),.bios_seen(bios_seen),
    .nv_save_freeze(nv_save_freeze),.save_error(save_error),.boot_error(boot_error));

wire [31:0] nv_bridge_data;
wire [64:0] rtc_host=rtc_valid ?
    {9'b0,4'b0,rtc_time_bcd[27:24],rtc_date_bcd[23:0],rtc_time_bcd[23:0]} :
    {9'b0,8'h00,8'h94,8'h01,8'h01,24'h000000};
wire [64:0] rtc_sys;
// RTC is a boot-time stable bundle; synchronize its validity along with data.
pocket_sync #(.WIDTH(65)) rtc_sync(.clk(clk_sys),.d(rtc_host),.q(rtc_sys));
wire [31:0] keys_sys;
pocket_sync #(.WIDTH(32)) keys(.clk(clk_sys),.d(cont1_key),.q(keys_sys));
bytestream slave_tx(),slave_rx(),uart_tx_unused(),uart_rx_unused();
assign uart_rx_unused.write=1'b0;
assign uart_rx_unused.data=8'b0;
wire slave_rts;
pocket_controller controller(.clk(clk_machine),.reset(core_reset),.keys(keys_sys),
    .rts(slave_rts),.serial_out(slave_rx));
rgb888_s rgb;
wire [15:0] left,right;
wire cd_short,cd_long;
wire video_initialized;
cditop machine(.clk30(clk_machine),.clk_audio(clk_machine),.external_reset(core_reset),
    .tvmode_pal(!ntsc_sys),.audio_cd_in_tray(1'b0),.ce_pix(ce),
    .HBlank(hblank),.HSync(hs),.VBlank(vblank_cdi),.VSync(vs),.vga_f1(field),
    .video_interlaced(interlaced),.video_initialized(video_initialized),.vidout(rgb),
    .sdram_addr(cdi_mem_addr),.sdram_rd(cdi_mem_rd),.sdram_wr(cdi_mem_wr),
    .sdram_word(cdi_mem_word),.sdram_din(cdi_mem_din),.sdram_dout(mem_dout),
    .sdram_busy(mem_busy),.sdram_burst(cdi_mem_burst),.sdram_refresh(cdi_mem_refresh),
    .sdram_burstdata_valid(mem_valid),.scc68_uart_tx(dbg_tx),.scc68_uart_rx(1'b1),
    .slave_worm_adr(slave_addr),.slave_worm_data(slave_data),.slave_worm_wr(slave_wr),
    .nvram_backup_restore_adr({bridge_addr[12:2],2'b00}),.nvram_bridge_clk(clk_74a),
    .nvram_restore_data(bridge_wr_data),.nvram_backup_data(nv_bridge_data),
    .nvram_restore_write(bridge_wr && bridge_addr[31:13]==19'h20000),
    .nvram_cpu_changed(nv_changed),.nvram_allow_cpu_access(nv_allowed),
    .slave_serial_out(slave_tx),.slave_serial_in(slave_rx),.slave_rts(slave_rts),.rc_eye(1'b1),
    .scc68070_bypass_serial_out(uart_tx_unused),.scc68070_bypass_serial_in(uart_rx_unused),
    .scc68070_rts(),.cd_seek_lba(seek_lba),.cd_seek_lba_valid(seek_valid),
    .cd_data(cd_data),.cd_data_valid(cd_valid),.cd_sector_tick(sector_tick),
    .cd_sector_delivered(sector_delivered),.cd_stop_sector_delivery(stop_delivery),
    .cd_img_mount(mounted_sys && !mount_q),.cd_img_mounted(mounted_sys),.tray_is_closed(),
    .audio_left(left),.audio_right(right),.fail_not_enough_words(cd_short),
    .fail_too_much_data(cd_long),.hps_rtc(rtc_sys));

assign video_rgb_clock=clk_sys;
assign video_rgb_clock_90=clk_sys_90;
pocket_video video(.clk(clk_sys),.reset(platform_reset),.machine_reset(core_reset),
    .picture_ready(video_initialized),.rgb({rgb.r,rgb.g,rgb.b}),
    .hblank(hblank),.vblank(vblank_cdi),.hs(hs),.vs(vs),.ce(ce),
    .interlaced(interlaced),.field(interlaced && !field),.video_rgb(video_rgb),.video_de(video_de),
    .video_skip(video_skip),.video_hs(video_hs),.video_vs(video_vs));
assign audio_mclk=clk_audio;
wire audio_reset;
pocket_reset audio_rst(.clk(clk_audio),.release_n(!core_reset),.reset(audio_reset));
pocket_audio sound(.clk_sys(clk_sys),.clk_audio(clk_audio),.reset(audio_reset),.mute(audio_mute),
    .left(left),.right(right),.dac(audio_dac),.lrck(audio_lrck));

reg [31:0] status_register_data;
always @* begin
    status_register_data=0;
    case(bridge_addr[7:0])
            0: status_register_data={31'b0,ntsc};
            4: status_register_data={24'b0,slave_seen,bios_seen,assets_complete,
                memory_idle_host,memory_ready_host,loader_overflow,reset_n,pll_locked_host};
            8: status_register_data={23'b0,boot_error,save_error,cd_last_error};
            12: status_register_data=image_size;
            16: status_register_data=disc_diagnostic;
            default: status_register_data=0;
    endcase
end
pocket_bridge_reply bridge_reply(.clk(clk_74a),.rd(bridge_rd),.addr(bridge_addr),
    .command_data(cmd_bridge_rd_data),.nvram_data(nv_bridge_data),
    .disc_data(disc_bridge_data),.register_data(status_register_data),.q(bridge_rd_data));
endmodule
`default_nettype wire
