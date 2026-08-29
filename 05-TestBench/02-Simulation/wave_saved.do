onerror {resume}
radix define color_fsm {
    "0 ST_CAM_RESET_ASSERT -color Orange" "1 ST_CAM_RESET_WAIT -color Cyan",
    "2 ST_PAGE_SEL_FILL -color Yellow" "3 ST_PAGE_SEL_START -color White",
    "4 ST_PAGE_SEL_WAIT -color Blue" "5 ST_CHIPID_RD_START -color White",
    "6 ST_CHIPID_RD_WAIT -color Blue" "7 ST_CHIPID_RD_DRAIN -color Magenta",
    "8 ST_FINISH -color Green" "9 ST_ERROR -color Red",
    -default default
}
radix define ftdi_state_radix {
    "#" "TX",
    "/" "Reposo",
    "(Tonos" "Grises/Apagados)",
    "0" "ST_IDLE" -color "Gray",
    "1" "ST_HOLD" -color "Cyan",
    "#" "RX",
    "Bus" "-",
    "4" "fases",
    "(Tonos" "Azules/Cian)",
    "2" "ST_RX_OE" -color "Cyan",
    "3" "ST_RX_OE2" -color "LightBlue",
    "4" "ST_RX_RD" -color "Blue",
    "5" "ST_RX_RELEASE" -color "DeepSkyBlue",
    "#" "RX",
    "Decodificación" "de",
    "Bytes" "(Tonos",
    "Naranjas/Amarillos)" "6",
    "ST_CMD_BYTE1" "-color",
    "Orange" "7",
    "ST_CMD_BYTE2" "-color",
    "LightOrange" "8",
    "ST_CMD_BYTE3" "-color",
    "Yellow" "9",
    "ST_CMD_BYTE4" "-color",
    "Gold" "10",
    "ST_CMD_BYTE5" "-color",
    "LightYellow" "11",
    "ST_CMD_BYTE6" "-color",
    "Khaki" "#",
    "RX" "Ejecución",
    "(Verde" "-",
    "¡Acción!)" "12",
    "ST_CMD_EXEC" "-color",
    "Green" "",
    -default default
}
quietly WaveActivateNextPane {} 0
add wave -noupdate /testbench/s_basys3_led
add wave -noupdate /testbench/u_dut/s_led15_r
add wave -noupdate /testbench/s_basys3_cat
add wave -noupdate /testbench/s_basys3_an
add wave -noupdate /testbench/s_basys3_dp
add wave -noupdate /testbench/s_basys3_sw
add wave -noupdate /testbench/s_basys3_btn
add wave -noupdate -divider FSM
add wave -noupdate -radix color_fsm -radixenum symbolic -radixshowbase 1 /testbench/u_dut/s_state
add wave -noupdate -radix unsigned /testbench/u_dut/s_init_cnt
add wave -noupdate -divider {Reloj y Reset}
add wave -noupdate /testbench/s_clk_base
add wave -noupdate /testbench/s_rst_raw
add wave -noupdate /testbench/u_dut/s_mclk
add wave -noupdate /testbench/u_dut/s_locked
add wave -noupdate /testbench/u_dut/u_MMCM/clk_out1
add wave -noupdate /testbench/u_dut/u_MMCM/clk_out3
add wave -noupdate /testbench/u_dut/u_MMCM/clk_out2
add wave -noupdate -divider I2C
add wave -noupdate -height 30 /testbench/s_scl_bus
add wave -noupdate -radix unsigned /testbench/u_dut/s_i2c_busy
add wave -noupdate -height 30 /testbench/s_sda_bus
add wave -noupdate -radix unsigned /testbench/u_dut/s_i2c_done
add wave -noupdate -radix unsigned /testbench/u_dut/s_i2c_error
add wave -noupdate -divider <NULL>
add wave -noupdate -group i2c_agent /testbench/u_i2c_agent/scl_i
add wave -noupdate -group i2c_agent /testbench/u_i2c_agent/sda_io
add wave -noupdate -group i2c_agent /testbench/u_i2c_agent/s_regs_core
add wave -noupdate -group i2c_agent /testbench/u_i2c_agent/s_regs_ifp
add wave -noupdate -group i2c_agent /testbench/u_i2c_agent/s_reg_addr
add wave -noupdate -group i2c_agent /testbench/u_i2c_agent/s_debug_state
add wave -noupdate -divider -height 25 <NULL>
add wave -noupdate -group image_agent -divider -height 25 <NULL>
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/reset_i
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/fvalid_o
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/lvalid_o
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/data_o
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/s_state
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/s_col_cnt
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/s_row_cnt
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/s_blank_cnt
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/fvalid_r
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/lvalid_r
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/s_pix_num
add wave -noupdate -group image_agent /testbench/u_dut/u_cam_sim/clkin_i
add wave -noupdate -group image_agent /testbench/u_dut/s_mclk_div_cnt
add wave -noupdate -divider -height 25 <NULL>
add wave -noupdate -group {frame capture} /testbench/u_dut/s_cap_en
add wave -noupdate -group {frame capture} /testbench/u_dut/u_cmd_processor/cap_en_cmd_o
add wave -noupdate -group {frame capture} -label PIXLCLK /testbench/u_dut/u_frame_capture/pixclk_i
add wave -noupdate -group {frame capture} -label RESET /testbench/u_dut/u_frame_capture/reset_i
add wave -noupdate -group {frame capture} -label {FRAME VALID} /testbench/u_dut/u_frame_capture/fvalid_i
add wave -noupdate -group {frame capture} -label {LINE VALID} /testbench/u_dut/u_frame_capture/lvalid_i
add wave -noupdate -group {frame capture} -label DATA /testbench/u_dut/u_frame_capture/data_i
add wave -noupdate -group {frame capture} -label {CAPTURE EN} /testbench/u_dut/u_frame_capture/capture_en_i
add wave -noupdate -group {frame capture} -label {FIFO DATA} /testbench/u_dut/u_frame_capture/fifo_data_o
add wave -noupdate -group {frame capture} -label {FIFO WR} /testbench/u_dut/u_frame_capture/fifo_wr_o
add wave -noupdate -group {frame capture} -label {FIFO FULL} /testbench/u_dut/u_frame_capture/fifo_full_i
add wave -noupdate -group {frame capture} -label {FRAME DONE} /testbench/u_dut/u_frame_capture/frame_done_o
add wave -noupdate -group {frame capture} -label OVERFLOW /testbench/u_dut/u_frame_capture/overflow_o
add wave -noupdate -group {frame capture} -label {FSM STATE} /testbench/u_dut/u_frame_capture/s_state
add wave -noupdate -group {frame capture} -label {BYTE CNT} /testbench/u_dut/u_frame_capture/s_byte_cnt
add wave -noupdate -group {frame capture} -label {COL CNT} /testbench/u_dut/u_frame_capture/s_col_cnt
add wave -noupdate -group {frame capture} -label {ROW CNT} /testbench/u_dut/u_frame_capture/s_row_cnt
add wave -noupdate -group {frame capture} -label OVERFLOW /testbench/u_dut/u_frame_capture/overflow_r
add wave -noupdate -divider -height 25 <NULL>
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/rst
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/wr_clk
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/rd_clk
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/din
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/wr_en
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/rd_en
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/dout
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/full
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/empty
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/wr_rst_busy
add wave -noupdate -group ASYNC_FIFO /testbench/u_dut/u_async_fifo/rd_rst_busy
add wave -noupdate -divider -height 25 <NULL>
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/clk_i
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/reset_i
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/fifo_data_i
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/fifo_empty_i
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/fifo_rd_en_o
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/txe_n_i
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/wr_n_o
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/adbus_o
add wave -noupdate -group FTDI_CTRL /testbench/u_dut/u_ftdi_ctrl/tx_active_o
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/rxf_n_i
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/adbus_oe
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/s_oe_n
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/s_rd_n
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/adbus_i
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/s_cmd_valid_r
add wave -noupdate /testbench/u_dut/u_ftdi_ctrl/s_rx_state
add wave -noupdate -divider -height 25 <NULL>
add wave -noupdate /testbench/u_dut/u_cmd_processor/s_data_sync1
add wave -noupdate -divider -height 25 <NULL>
add wave -noupdate -expand -group ftdi_agent /testbench/u_ftdi_agent/acbus_io
add wave -noupdate -expand -group ftdi_agent /testbench/u_ftdi_agent/adbus_io
add wave -noupdate -expand -group ftdi_agent /testbench/u_ftdi_agent/s_clkout
add wave -noupdate -expand -group ftdi_agent /testbench/u_ftdi_agent/s_txe_n
add wave -noupdate -expand -group ftdi_agent /testbench/u_ftdi_agent/s_rxf_n
add wave -noupdate -expand -group ftdi_agent -label OE# /testbench/u_ftdi_agent/acbus_io(6)
add wave -noupdate -expand -group ftdi_agent -radix unsigned /testbench/u_ftdi_agent/s_rx_fifo_level
add wave -noupdate -expand -group ftdi_agent /testbench/u_ftdi_agent/s_tx_fifo_dout
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_valid_sync0
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_valid_sync1
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_valid_sync2
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_type_sync0
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_type_sync1
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_data_sync0
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_data_sync1
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_page_sync0
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_page_sync1
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_addr_sync0
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_addr_sync1
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_cmd_pulse
add wave -noupdate -expand -group {CMD PROCESSOR} /testbench/u_dut/u_cmd_processor/s_exec_state
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {550452981 ps} 0} {{Cursor 2} {2433833651 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 553
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits us
update
WaveRestoreZoom {550234960 ps} {550535526 ps}
