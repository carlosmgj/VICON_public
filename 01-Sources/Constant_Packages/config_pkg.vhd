--! \file config_pkg.vhd
--! \brief Paquete de configuración global de VICON.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;

PACKAGE config_pkg IS
    
    ---------------------------------------------------------------------------
    -- DEBUG
    ---------------------------------------------------------------------------
    CONSTANT c_USE_ILA               : BOOLEAN := TRUE; --! TRUE → ILA activo (síntesis); FALSE → sin ILA (simulación)
    
    ---------------------------------------------------------------------------
    -- Sistema
    ---------------------------------------------------------------------------
    CONSTANT c_SYSTEM_CLK_FREQ_HZ    : INTEGER := 100_000_000; --! Frecuencia del reloj de sistema generado por el MMCM (Hz)
    
    ---------------------------------------------------------------------------
    -- Basys 3 — Recursos de la placa de evaluación
    ---------------------------------------------------------------------------
    CONSTANT c_BASYS3_SW_QTY         : INTEGER := 16; --! Número de interruptores deslizantes
    CONSTANT c_BASYS3_LED_QTY        : INTEGER := 16; --! Número de LEDs
    CONSTANT c_BASYS3_7SEG_BAR_QTY   : INTEGER := 7;  --! Segmentos por dígito del display 7 segmentos
    CONSTANT c_BASYS3_7SEG_DIGIT_QTY : INTEGER := 4;  --! Número de dígitos del display 7 segmentos
    CONSTANT c_BASYS3_BTN_QTY        : INTEGER := 5;  --! Número de pulsadores \warning original era 4, pero hay 5 definidos (0..4)
    CONSTANT c_BASYS3_BTN_CENTER     : INTEGER := 0;  --! Índice del pulsador central
    CONSTANT c_BASYS3_BTN_RIGHT      : INTEGER := 1;  --! Índice del pulsador derecho
    CONSTANT c_BASYS3_BTN_TOP        : INTEGER := 2;  --! Índice del pulsador superior
    CONSTANT c_BASYS3_BTN_LEFT       : INTEGER := 3;  --! Índice del pulsador izquierdo
    CONSTANT c_BASYS3_BTN_DOWN       : INTEGER := 4;  --! Índice del pulsador inferior

    ---------------------------------------------------------------------------
    -- MT9V111 — Sensor óptico
    ---------------------------------------------------------------------------
    CONSTANT c_MT9V111_I2C_FREQ_HZ      : INTEGER                       := 200_000;   --! Frecuencia del bus I2C (Hz); MT9V111 soporta hasta 400 kHz (parece que falla a 400)
    CONSTANT c_MT9V111_I2C_FIFO_DEPTH   : INTEGER                       := 16;        --! Profundidad de las FIFOs de escritura y lectura I2C
    CONSTANT c_MT9V111_I2C_SENSOR_ADDR  : STD_LOGIC_VECTOR(6 DOWNTO 0)  := "1011100"; --! Dirección I2C de 7 bits del MT9V111 (0x5C)
    CONSTANT c_MT9V111_DATA_BITS        : INTEGER                       := 8;         --! Anchura del bus de datos de imagen del sensor
    CONSTANT c_MT9V111_MCLK_DIV         : INTEGER                       := 2;         --! Deprecated, usamos salida mmcm. Divisor de c_SYSTEM_CLK_FREQ_HZ para generar mt_clk_o = mclk/(div*2)
    CONSTANT c_MT9V111_CHIP_ID_EXPECTED : STD_LOGIC_VECTOR(15 DOWNTO 0) := x"823A";   --! Chip ID fijo del MT9V111 (registro 0xFF, page 0)
    CONSTANT c_MT9V111_H_RES            : INTEGER                       := 640;       --! Resolución horizontal del sensor en píxeles
    CONSTANT c_MT9V111_V_RES            : INTEGER                       := 480;       --! Resolución vertical del sensor en píxeles 
    CONSTANT c_MT9V111_RESET_HOLD_US    : INTEGER                       := 1;         --! Tiempo mínimo de RESET# a nivel bajo (µs)
    CONSTANT c_MT9V111_RESET_WAIT_US    : INTEGER                       := 150_000;   --! Tiempo de espera tras liberar RESET# para estabilización del PLL (µs)
    CONSTANT c_MT9V111_FPS              : INTEGER                       := 30     ;   --! FPS que genera el sensor por defecto
    CONSTANT c_MT9V111_TARGET_FPS       : INTEGER                       := 30     ;   --! FPS que deseamos adquirir, descartando los restantes. No puede ser mayor que c_MT9V111_FPS
    
    -----------------------------------------------------------------------------------------------------
    -- MT9V111 IMAGE — Uso de generación de imagen sintética (cam_sim) en Hardware para pruebas en simulación y en placa
    -------------------------------------------------------------------------------------------------------
    CONSTANT c_USE_CAM_SIM    : BOOLEAN := TRUE;  --! 1: Usar datos de imagen simulada, 0: usar datos de imagen real
    CONSTANT c_CAM_SIM_H_RES  : INTEGER := 640;   --! Resolución horizontal de la imagen sintética generada en píxeles
    CONSTANT c_CAM_SIM_V_RES  : INTEGER := 480;   --! Resolución vertical de la imagen sintética generada en líneas
    CONSTANT c_CAM_SIM_HBLANK : INTEGER := 300;   --! Blanking horizontal de la imagen sintética (ciclos pixclk): similar a P1 real
    CONSTANT c_CAM_SIM_VBLANK : INTEGER := 20778; --! Blanking vertical de la imagen sintética (filas): similar a Reg0x06+9 real

    ---------------------------------------------------------------------------
    -- FT232H — Chip FTDI en modo Synchronous FIFO
    ---------------------------------------------------------------------------
    CONSTANT c_FTDI_DATABUS_W    : INTEGER := 8; --! Anchura del bus de datos ADBUS (bits)
    CONSTANT c_FTDI_CONTROLBUS_W : INTEGER := 8; --! Anchura del bus de control ACBUS (bits)
    CONSTANT c_FTDI_ACBUS_RXF_N  : INTEGER := 0; --! RXF#   — RX empty flag  (entrada): '0'=dato disponible para leer
    CONSTANT c_FTDI_ACBUS_TXE_N  : INTEGER := 1; --! TXE#   — TX full flag   (entrada): '0'=FT232H listo para recibir
    CONSTANT c_FTDI_ACBUS_RD_N   : INTEGER := 2; --! RD#    — read strobe    (salida):  '0'=leer byte de ADBUS
    CONSTANT c_FTDI_ACBUS_WR_N   : INTEGER := 3; --! WR#    — write strobe   (salida):  '0'=escribir byte en ADBUS
    CONSTANT c_FTDI_ACBUS_SIWU_N : INTEGER := 4; --! SIWU#  — send immediate (salida):  mantenido a '1' (inactivo)
    CONSTANT c_FTDI_ACBUS_CLKOUT : INTEGER := 5; --! CLKOUT — reloj 60 MHz   (entrada): entra vía BUFG como s_ftdi_clk
    CONSTANT c_FTDI_ACBUS_OE_N   : INTEGER := 6; --! OE#    — output enable  (salida):  mantenido a '1' (solo escritura)
    CONSTANT c_FTDI_ACBUS_PWRSAV : INTEGER := 7; --! PWRSAV — power save     (salida):  mantenido a '1' (activo)

    -- Marcador de inicio de frame (protocolo FPGA → Python)
    CONSTANT c_FRAME_MARKER_0 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"AA"; --! Byte 0 del marcador
    CONSTANT c_FRAME_MARKER_1 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"55"; --! Byte 1 del marcador
    CONSTANT c_FRAME_MARKER_2 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"AA"; --! Byte 2 del marcador
    CONSTANT c_FRAME_MARKER_3 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"55"; --! Byte 3 del marcador

    -- Valores reservados por el protocolo — no pueden aparecer en datos de imagen
    CONSTANT c_PROTO_RESERVED_FF : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"FF"; --! Sustituido por 0xFE
    CONSTANT c_PROTO_RESERVED_00 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00"; --! Sustituido por 0x01
    CONSTANT c_PROTO_RESERVED_AA : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"AA"; --! Sustituido por 0xAB
    CONSTANT c_PROTO_RESERVED_55 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"55"; --! Sustituido por 0x56

    CONSTANT c_PROTO_REPLACE_FF : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"FE"; --! Sustituto de 0xFF en datos de imagen
    CONSTANT c_PROTO_REPLACE_00 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"01"; --! Sustituto de 0x00 en datos de imagen
    CONSTANT c_PROTO_REPLACE_AA : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"AB"; --! Sustituto de 0xAA en datos de imagen
    CONSTANT c_PROTO_REPLACE_55 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"56"; --! Sustituto de 0x55 en datos de imagen

END PACKAGE config_pkg;