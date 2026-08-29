## \file sim_uvvm.do
## \brief Script de simulación QuestaSim para VICON (con librerías UVVM).
##
## Compila el diseño completo (fuentes + testbench + IPs de Xilinx),
## mapea las librerías de UVVM y de simulación de Vivado, optimiza
## preservando visibilidad de señales internas, y lanza la simulación
## con la ventana de waves ya configurada.
##
## \par Requisitos previos
## - UVVM ya compilado en <tt>C:/UVVM</tt> (no lo compila este script,
##   solo lo mapea — ver \ref page_setup / compile_all.do de UVVM)
## - Librerías de simulación de Vivado ya compiladas para QuestaSim
##   (Tools -> Compile Simulation Libraries) en la ruta indicada por
##   la variable <tt>SIMLIB</tt>
## - Proyecto Vivado con las IPs generadas (Generate Output Products)
##
## \par Cómo se ejecuta
## Desde QuestaSim, con la consola abierta en
## <tt>VICON/05-TestBench/02-Simulation/</tt>:
## \code
## do sim_uvvm.do
## \endcode
##
## \par Estructura del script (en orden)
## | Paso | Qué hace |
## |------|----------|
## | 1 | Crear/mapear la librería <tt>work</tt> (borra la anterior si existe) |
## | 2 | Mapear librerías UVVM ya compiladas |
## | 3 | Mapear librerías de simulación de Vivado (unisim, xpm, etc.) |
## | 4 | Compilar las IPs de Xilinx (clk_wiz_0, fifo_generator_0) |
## | 5 | Compilar las fuentes del diseño, en orden de dependencias |
## | 6 | Compilar las fuentes del testbench |
## | 7 | <tt>vopt</tt> con <tt>+acc</tt> (preserva señales internas en las waves) |
## | 8 | <tt>vsim</tt> y carga de waves/colores guardados si existen |
## | 9 | Breakpoint automático cada 50 frames capturados |
##
## \warning clk_wiz_0 se compila desde su netlist <b>VHDL</b>
## (<tt>clk_wiz_0_sim_netlist.vhdl</tt>), nunca el <tt>.v</tt> — la versión
## Verilog provoca un error fatal de elaboración con el primitivo
## <tt>MMCME2_ADV</tt> de <tt>unisim</tt> (ver \ref page_questasetup).
##
## \par Procedimientos disponibles tras cargar el script
## - <tt>recompile</tt> — recompila y relanza este mismo script desde cero
## - <tt>rerun</tt> — reinicia la simulación y corre 50 us, sin recompilar

# =============================================================================
# sim.do — Script de simulación QuestaSim para VICON
# Ejecutar desde: VICON/05-TestBench/02-Simulation/
# =============================================================================

# -----------------------------------------------------------------------------
# Rutas base (relativas al directorio donde se ejecuta este script)
# -----------------------------------------------------------------------------
set ROOT       "../../"
set SRC        "${ROOT}01-Sources"
set TB_SRC     "${ROOT}05-TestBench/01-Sources"
set IP_GEN     "${ROOT}06-Project/vicon_cmgj/vicon_cmgj.gen/sources_1/ip"
set VIVADO     "C:/Xilinx/Vivado/2020.2"
set SIMLIB     "${ROOT}06-Project/vicon_cmgj/vicon_cmgj.cache/compile_simlib/questa"
set UVVM       "C:/UVVM"

# -----------------------------------------------------------------
# Procedimientos de utilidad
#   recompile: recarga el propio script desde cero (recompila todo)
#   rerun:     reinicia la simulacion y corre 50us, sin recompilar
# ----------------
namespace eval :: {
    proc recompile {} {
        restart -force
        uplevel #0 source sim.do
    }

    proc rerun {} {
        restart -force
        run 50 us
    }
}

# -----------------------------------------------------------------------------
# Crear y mapear librería de trabajo
# -----------------------------------------------------------------------------
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

# -----------------------------------------------------------------------------
# Mapear librerías UVVM (ya compiladas en C:/UVVM)
# compile_all.do solo necesita ejecutarse una vez; después solo mapeamos
# -----------------------------------------------------------------------------
vmap uvvm_util              "${UVVM}/uvvm_util/sim/uvvm_util"
vmap uvvm_assertions        "${UVVM}/uvvm_assertions/sim/uvvm_assertions"
vmap uvvm_vvc_framework     "${UVVM}/uvvm_vvc_framework/sim/uvvm_vvc_framework"
vmap bitvis_vip_scoreboard  "${UVVM}/bitvis_vip_scoreboard/sim/bitvis_vip_scoreboard"
vmap bitvis_vip_i2c         "${UVVM}/bitvis_vip_i2c/sim/bitvis_vip_i2c"

# -----------------------------------------------------------------------------
# Mapear librerías de simulación de Vivado (necesarias para las IPs)
# -----------------------------------------------------------------------------
vmap unisim              "${SIMLIB}/unisim"
vmap unisims_ver         "${SIMLIB}/unisims_ver"
vmap secureip            "${SIMLIB}/secureip"
vmap xpm                 "${SIMLIB}/xpm"
vmap xilinx_vip          "${SIMLIB}/xilinx_vip"
vmap fifo_generator_v13_2_5 "${SIMLIB}/fifo_generator_v13_2_5"

# -----------------------------------------------------------------------------
# Compilar IPs de Xilinx
# NOTA: clk_wiz_0 usa el netlist VHDL — el .v provoca error en MMCME2_ADV
# -----------------------------------------------------------------------------
vcom -2008 -work work "${IP_GEN}/clk_wiz_0/clk_wiz_0_sim_netlist.vhdl"
vcom -2008 -work work "${IP_GEN}/fifo_generator_0/fifo_generator_0_sim_netlist.vhdl"

# -----------------------------------------------------------------------------
# Compilar fuentes del diseño (orden: dependencias primero)
# -----------------------------------------------------------------------------
vcom -2008 -work work "${SRC}/Constant_Packages/config_pkg.vhd"
vcom -2008 -work work "${SRC}/top_pkg.vhd"
vcom -2008 -work work "${SRC}/00-I2C_Controller/i2c_controller.vhd"
vcom -2008 -work work "${SRC}/01-Frame_Capture/frame_capture.vhd"
vcom -2008 -work work "${SRC}/02-FTDI_Controller/ftdi_controller.vhd"
vcom -2008 -work work "${SRC}/03-CMD_Processor/cmd_processor.vhd"
vcom -2008 -work work "${TB_SRC}/00-MT9V111/mt9v111_image.vhd"
vcom -2008 -work work "${TB_SRC}/stubs/ila_stub.vhd"
vcom -2008 -work work "${SRC}/TOP.vhd"

# -----------------------------------------------------------------------------
# Compilar fuentes del testbench
# -----------------------------------------------------------------------------
vcom -2008 -work work "${TB_SRC}/sim_utils_pkg.vhd"
vcom -2008 -work work "${TB_SRC}/clock_generator.vhd"
vcom -2008 -work work "${TB_SRC}/00-MT9V111/mt9v111_i2c.vhd"
vcom -2008 -work work "${TB_SRC}/01-FT232H/ftdi_agent.vhd"
vcom -2008 -suppress 1309 -work work "${TB_SRC}/testbench.vhd"

# -----------------------------------------------------------------------------
# Optimizar preservando visibilidad de señales internas
# -----------------------------------------------------------------------------
vopt work.testbench -o testbench_opt \
    +acc \
    -g g_MT9V111_RESET_HOLD_US=1 \
    -g g_MT9V111_RESET_WAIT_US=2 \
    -g g_MT9V111_I2C_FREQ_HZ=4000000 \
    -g g_USE_CAM_SIM=true \
    -g g_CAM_SIM_HBLANK=10 \
    -g g_CAM_SIM_VBLANK=20 \
    -g g_CAM_SIM_H_RES=100 \
    -g g_CAM_SIM_V_RES=5 \
    -g g_MT9V111_FPS=15 \
    -g g_MT9V111_TARGET_FPS=15 \
    -L unisim -L unisims_ver -L secureip \
    -L xpm -L xilinx_vip -L fifo_generator_v13_2_5 \
    -L uvvm_util -L uvvm_vvc_framework -L bitvis_vip_i2c

# -----------------------------------------------------------------------------
# Cargar simulación
# -----------------------------------------------------------------------------
vsim -wlf sim.wlf -t 1ps -fsmdebug \
    -L unisim \
    -L unisims_ver \
    -L secureip \
    -L xpm \
    -L xilinx_vip \
    -L fifo_generator_v13_2_5 \
    -L uvvm_util \
    -L uvvm_vvc_framework \
    -L bitvis_vip_i2c \
    work.testbench_opt

# -----------------------------------------------------------------------------
# Cargar wave personalizado si existe (señales añadidas manualmente)
# -----------------------------------------------------------------------------
if {[file exists wave_saved.do]} {
    echo "Cargando las señales en el wave"
    do wave_saved.do
}

# Cargar los colores del estado del FTDI justo aquí:
if {[file exists radix.do]} {
    echo "Aplicando colores al estado del FTDI..."
    do radix.do
}

# -----------------------------------------------------------------------------
# Configurar ventana de waves
# -----------------------------------------------------------------------------
configure wave -timelineunits us
WaveRestoreZoom {0} {100 us}

# -----------------------------------------------------------------------------
# Breakpoints — parar automáticamente
# -----------------------------------------------------------------------------
set frame_cnt 0
when {/testbench/u_dut/u_frame_capture/frame_done_o'event and /testbench/u_dut/u_frame_capture/frame_done_o = '1'} {
    global frame_cnt
    incr frame_cnt
    echo "Frame $frame_cnt completado en $now"
    if {$frame_cnt >= 50} {
        run 100 us
        stop
    }
}
run -all
