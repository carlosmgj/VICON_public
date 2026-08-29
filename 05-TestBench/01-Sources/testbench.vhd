--! \file testbench.vhd
--! \brief Testbench de integracion completo de VICON.
--! \author Carlos Manuel Gomez Jimenez

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

LIBRARY work;
USE work.config_pkg.ALL;
USE work.sim_utils_pkg.ALL;
USE work.top_pkg.ALL;

LIBRARY uvvm_util;
CONTEXT uvvm_util.uvvm_util_context;

ENTITY testbench IS
    GENERIC (
        g_MT9V111_RESET_HOLD_US   : INTEGER                      := c_MT9V111_RESET_HOLD_US;
        g_MT9V111_RESET_WAIT_US   : INTEGER                      := c_MT9V111_RESET_WAIT_US;
        g_MT9V111_H_RES           : INTEGER                      := c_MT9V111_H_RES;
        g_MT9V111_V_RES           : INTEGER                      := c_MT9V111_V_RES;
        g_MT9V111_I2C_FREQ_HZ     : INTEGER                      := c_MT9V111_I2C_FREQ_HZ;
        g_MT9V111_FPS             : INTEGER                      := c_MT9V111_FPS;
        g_MT9V111_TARGET_FPS      : INTEGER                      := c_MT9V111_TARGET_FPS;
        g_MT9V111_I2C_SENSOR_ADDR : STD_LOGIC_VECTOR(6 DOWNTO 0) := c_MT9V111_I2C_SENSOR_ADDR;
        g_USE_CAM_SIM             : BOOLEAN                      := c_USE_CAM_SIM;
        g_CAM_SIM_HBLANK          : INTEGER                      := c_CAM_SIM_HBLANK;
        g_CAM_SIM_VBLANK          : INTEGER                      := c_CAM_SIM_VBLANK;
        g_CAM_SIM_H_RES           : INTEGER                      := c_CAM_SIM_H_RES;
        g_CAM_SIM_V_RES           : INTEGER                      := c_CAM_SIM_V_RES
    );
END ENTITY testbench;

ARCHITECTURE sim OF testbench IS

    SIGNAL s_clk_base : STD_LOGIC;
    SIGNAL s_rst_raw  : STD_LOGIC;

    --! Reloj de pixel del sensor MT9V111 (25 MHz, igual que create_clock en el XDC).
    --! En la arquitectura actual, u_cam_sim/frame_capture/u_async_fifo.wr_clk
    --! se clockean con mt_pixclk_i, asi que necesita un generador propio aqui
    --! (en hardware lo proporciona siempre el sensor, este o no seleccionado).
    CONSTANT c_MT_PIXCLK_PERIOD : TIME := 40 ns;  --! 25 MHz
    SIGNAL s_mt_pixclk : STD_LOGIC := '0';

    SIGNAL s_scl_bus : STD_LOGIC := 'H';
    SIGNAL s_sda_bus : STD_LOGIC := 'H';

    SIGNAL s_mt_reset_n : STD_LOGIC;

    SIGNAL s_ftdi_acbus : STD_LOGIC_VECTOR(c_FTDI_CONTROLBUS_W-1 DOWNTO 0) := (OTHERS => 'Z');
    SIGNAL s_ftdi_adbus : STD_LOGIC_VECTOR(c_FTDI_DATABUS_W-1    DOWNTO 0) := (OTHERS => 'Z');
    SIGNAL s_basys3_sw  : STD_LOGIC_VECTOR(c_BASYS3_SW_QTY-1         DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_basys3_led : STD_LOGIC_VECTOR(c_BASYS3_LED_QTY-1        DOWNTO 0);
    SIGNAL s_basys3_btn : STD_LOGIC_VECTOR(c_BASYS3_BTN_QTY-1        DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_basys3_cat : STD_LOGIC_VECTOR(c_BASYS3_7SEG_BAR_QTY-1   DOWNTO 0);
    SIGNAL s_basys3_dp  : STD_LOGIC;
    SIGNAL s_basys3_an  : STD_LOGIC_VECTOR(c_BASYS3_7SEG_DIGIT_QTY-1 DOWNTO 0);

    ALIAS a_fsm_state  IS <<SIGNAL u_dut.s_state                       : main_state_t>>;
    ALIAS a_frame_done IS <<SIGNAL u_dut.u_frame_capture.frame_done_o  : STD_LOGIC>>;
    ALIAS a_rd_data    IS <<SIGNAL u_dut.s_i2c_rd_data                 : STD_LOGIC_VECTOR(15 DOWNTO 0)>>;
    ALIAS a_cfg_idx    IS <<SIGNAL u_dut.s_cfg_idx                     : INTEGER RANGE 0 TO 12>>;

    ---------------------------------------------------------------------------
    -- Funcion auxiliar: convierte STD_LOGIC a STRING ACK/NACK
    ---------------------------------------------------------------------------
    FUNCTION ack_str(a : STD_LOGIC) RETURN STRING IS
    BEGIN
        IF To_X01(a) = '0' THEN RETURN "ACK";
        ELSE                     RETURN "NACK";
        END IF;
    END FUNCTION;

BEGIN

    s_scl_bus <= 'H';
    s_sda_bus <= 'H';

    u_clk_rst : ENTITY work.clk_reset_gen
        PORT MAP (clk_out => s_clk_base, reset_out => s_rst_raw);

    --! \brief Generador de mt_pixclk_i (25 MHz) — dominio de pixel independiente
    --! de s_clk_base/s_mclk. Necesario para que u_cam_sim/frame_capture avancen.
    p_mt_pixclk : PROCESS
    BEGIN
        LOOP
            s_mt_pixclk <= '0';
            WAIT FOR c_MT_PIXCLK_PERIOD / 2;
            s_mt_pixclk <= '1';
            WAIT FOR c_MT_PIXCLK_PERIOD / 2;
        END LOOP;
    END PROCESS p_mt_pixclk;

    u_dut : ENTITY work.TOP
        GENERIC MAP (
            g_USE_ILA               => FALSE,
            g_MT9V111_RESET_HOLD_US => g_MT9V111_RESET_HOLD_US,
            g_MT9V111_RESET_WAIT_US => g_MT9V111_RESET_WAIT_US,
            g_MT9V111_H_RES         => g_MT9V111_H_RES,
            g_MT9V111_V_RES         => g_MT9V111_V_RES,
            g_MT9V111_I2C_FREQ_HZ   => g_MT9V111_I2C_FREQ_HZ,
            g_USE_CAM_SIM           => TRUE,
            g_CAM_SIM_HBLANK        => g_CAM_SIM_HBLANK,
            g_CAM_SIM_VBLANK        => g_CAM_SIM_VBLANK,
            g_CAM_SIM_H_RES         => g_CAM_SIM_H_RES,
            g_CAM_SIM_V_RES         => g_CAM_SIM_V_RES,
            g_MT9V111_FPS           => g_MT9V111_FPS,
            g_MT9V111_TARGET_FPS    => g_MT9V111_TARGET_FPS
        )
        PORT MAP (
            basys3_clk_i  => s_clk_base,
            basys3_sw_i   => s_basys3_sw,
            basys3_led_o  => s_basys3_led,
            basys3_cat_o  => s_basys3_cat,
            basys3_dp_o   => s_basys3_dp,
            basys3_an_o   => s_basys3_an,
            basys3_btn_i  => s_basys3_btn,
            mt_data_i     => (OTHERS => '0'),
            mt_lvalid_i   => '0',
            mt_pixclk_i   => s_mt_pixclk,
            mt_fvalid_i   => '0',
            mt_reset_n_o  => s_mt_reset_n,
            mt_clk_o      => OPEN,
            i2c_sclk_io   => s_scl_bus,
            i2c_sdata_io  => s_sda_bus,
            ftdi_adbus_io => s_ftdi_adbus,
            ftdi_acbus_io => s_ftdi_acbus
        );

    u_i2c_agent : ENTITY work.mt9v111_i2c
        GENERIC MAP (g_I2C_ADDR => c_MT9V111_I2C_SENSOR_ADDR)
        PORT MAP (scl_i => s_scl_bus, sda_io => s_sda_bus);

    u_ftdi_agent : ENTITY work.ftdi_agent
        GENERIC MAP (
            g_LOG_FILE           => "ftdi_rx_log.txt",
            g_TX_FIFO_DEPTH      => 512,
            g_TXE_BUSY_THRESHOLD => 480,
            g_TXE_BUSY_CYCLES    => c_TXE_BUSY_CYCLES   -- 0 = siempre listo
            -- g_PC_TO_FPGA_DEPTH omitido -> default 0, RXF# fijo a '1'
            -- g_PC_TO_FPGA_LOOP  omitido -> default FALSE
        )
        PORT MAP (
            acbus_io => s_ftdi_acbus,
            adbus_io => s_ftdi_adbus   -- <-- cambio: adbus_i -> adbus_io
        );

    ---------------------------------------------------------------------------
    -- Monitor FSM
    ---------------------------------------------------------------------------
    p_monitor : PROCESS
        VARIABLE v_prev_state : main_state_t;
    BEGIN
        WAIT FOR 0 ns;
        enable_log_msg(ALL_MESSAGES);
        log(ID_SEQUENCER, "=== VICON Testbench arrancado ===", "TB");
        WAIT UNTIL s_rst_raw = '0';
        log(ID_SEQUENCER, "Reset liberado - FSM arranca", "TB");
        v_prev_state := a_fsm_state;
        LOOP
            WAIT ON a_fsm_state;
            IF a_fsm_state /= v_prev_state THEN
                CASE a_fsm_state IS
                    WHEN ST_CAM_RESET_ASSERT => log(ID_SEQUENCER, "FSM -> ST_CAM_RESET_ASSERT", "TB");
                    WHEN ST_CAM_RESET_WAIT   => log(ID_SEQUENCER, "FSM -> ST_CAM_RESET_WAIT", "TB");
                    WHEN ST_PAGE_SEL_FILL    => log(ID_SEQUENCER, "FSM -> ST_PAGE_SEL_FILL", "TB");
                    WHEN ST_PAGE_SEL_START   => log(ID_SEQUENCER, "FSM -> ST_PAGE_SEL_START", "TB");
                    WHEN ST_PAGE_SEL_WAIT    => log(ID_SEQUENCER, "FSM -> ST_PAGE_SEL_WAIT", "TB");
                    WHEN ST_CHIPID_RD_START  => log(ID_SEQUENCER, "FSM -> ST_CHIPID_RD_START", "TB");
                    WHEN ST_CHIPID_RD_WAIT   => log(ID_SEQUENCER, "FSM -> ST_CHIPID_RD_WAIT", "TB");
                    WHEN ST_CHIPID_RD_DRAIN  => log(ID_SEQUENCER, "FSM -> ST_CHIPID_RD_DRAIN", "TB");
                    WHEN ST_CFG_PAGE_FILL    => log(ID_SEQUENCER, "FSM -> ST_CFG_PAGE_FILL", "TB");
                    WHEN ST_CFG_PAGE_START   => log(ID_SEQUENCER, "FSM -> ST_CFG_PAGE_START", "TB");
                    WHEN ST_CFG_PAGE_WAIT    => log(ID_SEQUENCER, "FSM -> ST_CFG_PAGE_WAIT", "TB");
                    WHEN ST_CFG_WR_FILL      => log(ID_SEQUENCER, "FSM -> ST_CFG_WR_FILL", "TB");
                    WHEN ST_CFG_WR_START     => log(ID_SEQUENCER, "FSM -> ST_CFG_WR_START", "TB");
                    WHEN ST_CFG_WR_WAIT      => log(ID_SEQUENCER, "FSM -> ST_CFG_WR_WAIT", "TB");
                    WHEN ST_CFG_RD_START     => log(ID_SEQUENCER, "FSM -> ST_CFG_RD_START (verify)", "TB");
                    WHEN ST_CFG_RD_WAIT      => log(ID_SEQUENCER, "FSM -> ST_CFG_RD_WAIT", "TB");
                    WHEN ST_CFG_RD_DRAIN     =>
                        log(ID_SEQUENCER,
                            "FSM -> ST_CFG_RD_DRAIN  idx=" & to_string(a_cfg_idx) &
                            "  rd_data=0x" & to_hstring(a_rd_data), "TB");
                    WHEN ST_CFG_NEXT         => log(ID_SEQUENCER, "FSM -> ST_CFG_NEXT", "TB");
                    WHEN ST_FINISH           =>
                        log(ID_SEQUENCER, "FSM -> ST_FINISH *** Configuracion completada ***", "TB");
                        WAIT UNTIL rising_edge(s_clk_base);
                        WAIT UNTIL rising_edge(s_clk_base);
                        check_value(s_basys3_led(0), '1', ERROR,
                                    "LED(0) debe estar encendido en ST_FINISH", "TB");
                    WHEN ST_ERROR =>
                        alert(ERROR,
                            "FSM -> ST_ERROR - verify fallido en idx=" & to_string(a_cfg_idx) &
                            "  rd_data=0x" & to_hstring(a_rd_data));
                    WHEN OTHERS =>
                        log(ID_SEQUENCER, "FSM -> estado desconocido", "TB");
                END CASE;
                v_prev_state := a_fsm_state;
            END IF;
        END LOOP;
    END PROCESS p_monitor;

    ---------------------------------------------------------------------------
    -- Monitor de frames
    ---------------------------------------------------------------------------
    p_frame_monitor : PROCESS
        VARIABLE v_frame_cnt : natural := 0;
    BEGIN
        WAIT UNTIL s_rst_raw = '0';
        LOOP
            WAIT UNTIL rising_edge(a_frame_done);
            v_frame_cnt := v_frame_cnt + 1;
            log(ID_SEQUENCER, "Frame " & to_string(v_frame_cnt) & " completado", "TB");
        END LOOP;
    END PROCESS p_frame_monitor;

    ---------------------------------------------------------------------------
    -- Sniffer I2C
    -- Lee bit a bit del bus y decodifica START, STOP, RSTART, bytes y ACK/NACK
    ---------------------------------------------------------------------------
    p_i2c_sniffer : PROCESS

        -- Lee un bit. Devuelve el bit muestreado en flanco de subida de SCL.
        -- Si durante la ventana de SCL alto SDA cambia, reporta rstart o stop.
        PROCEDURE read_bit (
            VARIABLE b      : OUT STD_LOGIC;
            VARIABLE rstart : OUT BOOLEAN;
            VARIABLE stop   : OUT BOOLEAN
        ) IS
            VARIABLE v_sda_at_rise : STD_LOGIC;
        BEGIN
            b      := '0';
            rstart := FALSE;
            stop   := FALSE;

            -- Esperar flanco de subida de SCL
            WAIT UNTIL To_X01(s_scl_bus) = '1';
            v_sda_at_rise := To_X01(s_sda_bus);
            b := v_sda_at_rise;
            IF b = 'X' THEN b := '0'; END IF;

            -- Mientras SCL alto, vigilar cambio de SDA
            LOOP
                WAIT ON s_scl_bus, s_sda_bus;
                -- SCL bajo: fin normal del bit
                IF To_X01(s_scl_bus) = '0' THEN
                    RETURN;
                END IF;
                -- SDA bajo con SCL alto: Repeated START
                IF To_X01(s_sda_bus) = '0' and To_X01(v_sda_at_rise) /= '0' THEN
                    rstart := TRUE;
                    RETURN;
                END IF;
                -- SDA alto con SCL alto: STOP
                IF To_X01(s_sda_bus) = '1' and To_X01(v_sda_at_rise) /= '1' THEN
                    stop := TRUE;
                    RETURN;
                END IF;
            END LOOP;
        END PROCEDURE;

        -- Lee 8 bits MSB primero + el pulso de ACK/NACK.
        -- Si detecta RSTART o STOP durante la lectura, sale inmediatamente.
        PROCEDURE read_byte_ack (
                VARIABLE data   : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
                VARIABLE ack    : OUT STD_LOGIC;
                VARIABLE rstart : OUT BOOLEAN;
                VARIABLE stop   : OUT BOOLEAN
            ) IS
                VARIABLE v_bit  : STD_LOGIC;
                VARIABLE v_rs   : BOOLEAN;
                VARIABLE v_st   : BOOLEAN;
            BEGIN
                data   := (OTHERS => '0');
                ack    := '1';
                rstart := FALSE;
                stop   := FALSE;

                FOR i IN 7 DOWNTO 0 LOOP
                    read_bit(v_bit, v_rs, v_st);
                    IF v_rs THEN rstart := TRUE; RETURN; END IF;
                    IF v_st THEN stop   := TRUE; RETURN; END IF;
                    data(i) := v_bit;
                END LOOP;

                -- Leer ACK/NACK
                read_bit(ack, v_rs, v_st);
                IF v_rs THEN rstart := TRUE; END IF;
                IF v_st THEN stop   := TRUE; END IF;
            END PROCEDURE;

        VARIABLE v_byte   : STD_LOGIC_VECTOR(7 DOWNTO 0);
        VARIABLE v_ack    : STD_LOGIC;
        VARIABLE v_rstart : BOOLEAN;
        VARIABLE v_stop   : BOOLEAN;
        VARIABLE v_sda_p  : STD_LOGIC := '1';

    BEGIN
        LOOP
            -- Esperar START: flanco de bajada de SDA con SCL alto
            WAIT UNTIL To_X01(s_sda_bus) = '0';
            IF To_X01(s_scl_bus) /= '1' THEN NEXT; END IF;

            log(ID_SEQUENCER, "I2C >> START", "SNIFFER");

            -- Leer byte de direccion
            read_byte_ack(v_byte, v_ack, v_rstart, v_stop);
            IF v_rstart THEN
                log(ID_SEQUENCER, "I2C >> RSTART (inesperado)", "SNIFFER");
                NEXT;
            END IF;
            IF v_stop THEN
                log(ID_SEQUENCER, "I2C >> STOP (inesperado)", "SNIFFER");
                NEXT;
            END IF;

            IF v_byte(0) = '0' THEN
                log(ID_SEQUENCER,
                    "I2C >> ADDR 0x" & to_hstring("0" & v_byte(7 DOWNTO 1)) &
                    " W  " & ack_str(v_ack), "SNIFFER");
            ELSE
                log(ID_SEQUENCER,
                    "I2C >> ADDR 0x" & to_hstring("0" & v_byte(7 DOWNTO 1)) &
                    " R  " & ack_str(v_ack), "SNIFFER");
            END IF;

            -- Leer bytes hasta STOP o RSTART
            LOOP
                read_byte_ack(v_byte, v_ack, v_rstart, v_stop);

                IF v_stop THEN
                    log(ID_SEQUENCER, "I2C >> STOP", "SNIFFER");
                    EXIT;
                END IF;

                IF v_rstart THEN
                    log(ID_SEQUENCER, "I2C >> RSTART", "SNIFFER");
                    -- Leer byte de direccion del Repeated START
                    read_byte_ack(v_byte, v_ack, v_rstart, v_stop);
                    IF v_byte(0) = '0' THEN
                        log(ID_SEQUENCER,
                            "I2C >> ADDR 0x" & to_hstring("0" & v_byte(7 DOWNTO 1)) &
                            " W  " & ack_str(v_ack), "SNIFFER");
                    ELSE
                        log(ID_SEQUENCER,
                            "I2C >> ADDR 0x" & to_hstring("0" & v_byte(7 DOWNTO 1)) &
                            " R  " & ack_str(v_ack), "SNIFFER");
                    END IF;
                    NEXT;  -- continuar leyendo bytes de la nueva direccion
                END IF;

                log(ID_SEQUENCER,
                    "I2C >> BYTE 0x" & to_hstring(v_byte) &
                    "  " & ack_str(v_ack), "SNIFFER");

            END LOOP;

        END LOOP;
    END PROCESS p_i2c_sniffer;

END ARCHITECTURE sim;