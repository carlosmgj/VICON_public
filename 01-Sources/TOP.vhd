--! \file TOP.vhd
--! \brief VICON: Top Level.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

LIBRARY UNISIM;
USE UNISIM.VComponents.ALL;

LIBRARY work;
USE work.config_pkg.ALL;

--! \brief Entidad de Sistema de Visión.
--! \fsm_show_actions
ENTITY TOP IS
    GENERIC (
        g_USE_ILA                   : BOOLEAN                      := c_USE_ILA;
        g_SYSTEM_CLK_FREQ_HZ        : INTEGER                      := c_SYSTEM_CLK_FREQ_HZ;
        g_MT9V111_MCLK_DIV          : INTEGER                      := c_MT9V111_MCLK_DIV;
        g_MT9V111_I2C_FREQ_HZ       : INTEGER                      := c_MT9V111_I2C_FREQ_HZ;
        g_MT9V111_I2C_FIFO_DEPTH    : INTEGER                      := c_MT9V111_I2C_FIFO_DEPTH;
        g_MT9V111_I2C_SENSOR_ADDR   : STD_LOGIC_VECTOR(6 DOWNTO 0) := c_MT9V111_I2C_SENSOR_ADDR;
        g_MT9V111_H_RES             : INTEGER                      := c_MT9V111_H_RES;
        g_MT9V111_V_RES             : INTEGER                      := c_MT9V111_V_RES;
        g_MT9V111_RESET_HOLD_US     : INTEGER                      := c_MT9V111_RESET_HOLD_US;
        g_MT9V111_RESET_WAIT_US     : INTEGER                      := c_MT9V111_RESET_WAIT_US;
        g_MT9V111_FPS               : INTEGER                      := c_MT9V111_FPS;
        g_MT9V111_TARGET_FPS        : INTEGER                      := c_MT9V111_TARGET_FPS;
        g_USE_CAM_SIM               : BOOLEAN                      := c_USE_CAM_SIM;
        g_CAM_SIM_HBLANK            : INTEGER                      := c_CAM_SIM_HBLANK;
        g_CAM_SIM_VBLANK            : INTEGER                      := c_CAM_SIM_VBLANK;
        g_CAM_SIM_H_RES             : INTEGER                      := c_CAM_SIM_H_RES;
        g_CAM_SIM_V_RES             : INTEGER                      := c_CAM_SIM_V_RES
    );
    PORT (
        basys3_clk_i   : IN    STD_LOGIC;
        basys3_sw_i    : IN    STD_LOGIC_VECTOR(c_BASYS3_SW_QTY-1         DOWNTO 0);
        basys3_led_o   : OUT   STD_LOGIC_VECTOR(c_BASYS3_LED_QTY-1        DOWNTO 0);
        basys3_cat_o   : OUT   STD_LOGIC_VECTOR(c_BASYS3_7SEG_BAR_QTY-1   DOWNTO 0);
        basys3_dp_o    : OUT   STD_LOGIC;
        basys3_an_o    : OUT   STD_LOGIC_VECTOR(c_BASYS3_7SEG_DIGIT_QTY-1 DOWNTO 0);
        basys3_btn_i   : IN    STD_LOGIC_VECTOR(c_BASYS3_BTN_QTY-1        DOWNTO 0);
        mt_data_i      : IN    STD_LOGIC_VECTOR(c_MT9V111_DATA_BITS-1     DOWNTO 0);
        mt_lvalid_i    : IN    STD_LOGIC;
        mt_pixclk_i    : IN    STD_LOGIC;
        mt_fvalid_i    : IN    STD_LOGIC;
        mt_reset_n_o   : OUT   STD_LOGIC;
        mt_clk_o       : OUT   STD_LOGIC;
        i2c_sclk_io    : INOUT STD_LOGIC;
        i2c_sdata_io   : INOUT STD_LOGIC;
        ftdi_adbus_io  : INOUT STD_LOGIC_VECTOR(c_FTDI_DATABUS_W-1        DOWNTO 0);  --! ADBUS bidireccional: TX imagen / RX comandos
        ftdi_acbus_io  : INOUT STD_LOGIC_VECTOR(c_FTDI_CONTROLBUS_W-1     DOWNTO 0)
    );
END ENTITY TOP;

ARCHITECTURE rtl OF TOP IS
    
    TYPE main_state_t IS (
        ST_CAM_RESET_ASSERT,    --! RESET# bajo durante RESET_HOLD_CYCLES
        ST_CAM_RESET_WAIT,      --! Espera RESET_WAIT_CYCLES para estabilizacion del PLL
        -- Lectura Chip ID
        ST_PAGE_SEL_FILL,       --! Encola page=0x0004 para leer Chip ID en 0xFF
        ST_PAGE_SEL_START,      --! Lanza escritura I2C reg 0x01
        ST_PAGE_SEL_WAIT,
        ST_CHIPID_RD_START,     --! Lanza lectura I2C reg 0xFF
        ST_CHIPID_RD_WAIT,
        ST_CHIPID_RD_DRAIN,     --! Extrae y verifica Chip ID
        -- Configuracion mediante subFSM write+verify
        ST_CFG_PAGE_FILL,       --! Encola el valor de page del registro actual
        ST_CFG_PAGE_START,      --! Lanza escritura Page Map (reg 0x01)
        ST_CFG_PAGE_WAIT,
        ST_CFG_WR_FILL,         --! Encola el dato del registro actual
        ST_CFG_WR_START,        --! Lanza escritura del registro
        ST_CFG_WR_WAIT,
        ST_CFG_RD_START,        --! Lanza lectura del mismo registro (verify)
        ST_CFG_RD_WAIT,
        ST_CFG_RD_DRAIN,        --! Compara readback con valor esperado
        ST_CFG_NEXT,            --! Avanza al siguiente registro o va a ST_FINISH
        -- Estados finales
        ST_FINISH,              --! Configuracion OK: captura activa
        ST_ERROR                --! Error I2C, Chip ID o verify fallido
    );

    ---------------------------------------------------------------------------
    -- Constantes de temporización
    ---------------------------------------------------------------------------
    CONSTANT c_MT9V111_RESET_HOLD_CYCLES : INTEGER :=
        (g_SYSTEM_CLK_FREQ_HZ / 1_000_000) * g_MT9V111_RESET_HOLD_US;
    CONSTANT c_MT9V111_RESET_WAIT_CYCLES : INTEGER :=
        (g_SYSTEM_CLK_FREQ_HZ / 1_000_000) * g_MT9V111_RESET_WAIT_US;
    CONSTANT c_CAP_H_RES : INTEGER :=
        g_CAM_SIM_H_RES * BOOLEAN'pos(g_USE_CAM_SIM) +
        g_MT9V111_H_RES * BOOLEAN'pos(NOT g_USE_CAM_SIM);
    CONSTANT c_CAP_V_RES : INTEGER :=
        g_CAM_SIM_V_RES * BOOLEAN'pos(g_USE_CAM_SIM) +
        g_MT9V111_V_RES * BOOLEAN'pos(NOT g_USE_CAM_SIM);

    ---------------------------------------------------------------------------
    -- Tabla de registros a configurar (Tabla 15 datasheet, MCLK=27 MHz -> 30 fps)
    -- Formato: (page, addr, value)
    --   page 0 = Core, page 1 = IFP
    ---------------------------------------------------------------------------
    TYPE t_reg_entry IS RECORD
        page : STD_LOGIC;                      --! '0'=Core, '1'=IFP
        addr : STD_LOGIC_VECTOR(7 DOWNTO 0);
        data : STD_LOGIC_VECTOR(15 DOWNTO 0);
    END RECORD;

    TYPE t_reg_table IS ARRAY (natural RANGE <>) OF t_reg_entry;

    CONSTANT c_CFG_TABLE : t_reg_table := (
        -- Core page (page 0)
        ('0', x"05", STD_LOGIC_VECTOR(to_unsigned(132,   16))),  --! R5  HBLANK
        ('0', x"06", STD_LOGIC_VECTOR(to_unsigned(10,    16))),  --! R6  VBLANK
        ('0', x"07", x"0000"),                                   --! R7  output format
        ('0', x"21", STD_LOGIC_VECTOR(to_unsigned(58369, 16))),  --! R33 shutter width
        -- IFP page (page 1)
        ('1', x"33", STD_LOGIC_VECTOR(to_unsigned(5137,  16))),  --! R51
        ('1', x"39", STD_LOGIC_VECTOR(to_unsigned(290,   16))),  --! R57
        ('1', x"3B", STD_LOGIC_VECTOR(to_unsigned(1068,  16))),  --! R59
        ('1', x"3E", STD_LOGIC_VECTOR(to_unsigned(4095,  16))),  --! R62
        ('1', x"59", STD_LOGIC_VECTOR(to_unsigned(504,   16))),  --! R89
        ('1', x"5A", STD_LOGIC_VECTOR(to_unsigned(605,   16))),  --! R90
        ('1', x"5C", STD_LOGIC_VECTOR(to_unsigned(8222,  16))),  --! R92
        ('1', x"5D", STD_LOGIC_VECTOR(to_unsigned(10021, 16))),  --! R93
        ('1', x"64", STD_LOGIC_VECTOR(to_unsigned(4477,  16)))   --! R100
        --('1', x"37", x"0080")  --! R55 [9:5]=4 -> frame rate minimo 30fps
    );

    CONSTANT c_CFG_TABLE_LEN : INTEGER := c_CFG_TABLE'length;  --! 13 entradas

    ---------------------------------------------------------------------------
    -- Relojes y reset
    ---------------------------------------------------------------------------
    SIGNAL s_mclk         : STD_LOGIC;
    SIGNAL s_locked       : STD_LOGIC;
    SIGNAL s_rst_final    : STD_LOGIC;
    SIGNAL s_mclk_div_cnt : INTEGER RANGE 0 TO g_MT9V111_MCLK_DIV - 1 := 0;
    SIGNAL cam_mclk_r     : STD_LOGIC := '0';  --! clk_out3 del MMCM (30 MHz) -> mt_clk_o

    ---------------------------------------------------------------------------
    -- Interfaz FSM <-> controlador I2C
    ---------------------------------------------------------------------------
    SIGNAL s_i2c_rw_fsm       : STD_LOGIC                                   := '0';
    SIGNAL s_i2c_start_fsm    : STD_LOGIC                                   := '0';
    SIGNAL s_i2c_num_regs_fsm : INTEGER RANGE 1 TO g_MT9V111_I2C_FIFO_DEPTH := 1;
    SIGNAL s_i2c_addr_reg_fsm : STD_LOGIC_VECTOR(7 DOWNTO 0)                := (OTHERS => '0');
    SIGNAL s_i2c_wr_push_fsm  : STD_LOGIC                                   := '0';
    SIGNAL s_i2c_wr_data_fsm  : STD_LOGIC_VECTOR(15 DOWNTO 0)               := (OTHERS => '0');
    SIGNAL s_i2c_rd_pop_fsm   : STD_LOGIC                                   := '0';
    SIGNAL s_i2c_wr_full  : STD_LOGIC;
    SIGNAL s_i2c_wr_empty : STD_LOGIC;
    SIGNAL s_i2c_rd_data  : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL s_i2c_rd_full  : STD_LOGIC;
    SIGNAL s_i2c_rd_empty : STD_LOGIC;
    SIGNAL s_i2c_busy     : STD_LOGIC;
    SIGNAL s_i2c_done     : STD_LOGIC;
    SIGNAL s_i2c_error    : STD_LOGIC;
    SIGNAL s_scl_out      : STD_LOGIC;
    SIGNAL s_sda_out      : STD_LOGIC;
    SIGNAL s_sda_oe       : STD_LOGIC;
    SIGNAL s_sda_in       : STD_LOGIC;

    ---------------------------------------------------------------------------
    -- FTDI
    ---------------------------------------------------------------------------
    SIGNAL s_ftdi_clk       : STD_LOGIC;
    SIGNAL s_ftdi_txe_n     : STD_LOGIC;
    SIGNAL s_ftdi_rxf_n     : STD_LOGIC;                    --! RXF# - dato disponible del PC
    SIGNAL s_ftdi_wr_n      : STD_LOGIC;
    SIGNAL s_ftdi_rd_n      : STD_LOGIC;                    --! RD#  - strobe de lectura
    SIGNAL s_ftdi_oe_n      : STD_LOGIC;                    --! OE#  - habilita salida FTDI en ADBUS
    SIGNAL s_ftdi_adbus_out : STD_LOGIC_VECTOR(7 DOWNTO 0); --! ADBUS hacia el FTDI (TX imagen)
    SIGNAL s_ftdi_adbus_in  : STD_LOGIC_VECTOR(7 DOWNTO 0); --! ADBUS desde el FTDI (RX comandos)
    --! Tristate del bus, UNO POR BIT y en polaridad IOBUF.T ('0'=conduce, '1'=Hi-Z).
    --! Viene registrado per-bit del controlador -> empaqueta en el flop de tristate
    --! de cada IOB. NO meter logica (ni inversor) entre este vector y el buffer.
    SIGNAL s_ftdi_adbus_t   : STD_LOGIC_VECTOR(c_FTDI_DATABUS_W-1 DOWNTO 0);
    SIGNAL s_ftdi_tx_active : STD_LOGIC;

    -- Comandos decodificados - dominio ftdi_clk
    SIGNAL s_cmd_valid_ftdi : STD_LOGIC;
    SIGNAL s_cmd_type_ftdi  : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL s_cmd_data_ftdi  : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL s_cmd_page_ftdi  : STD_LOGIC;
    SIGNAL s_cmd_addr_ftdi  : STD_LOGIC_VECTOR(7 DOWNTO 0);

    ---------------------------------------------------------------------------
    -- FIFO de captura (pixclk -> ftdi_clk)
    ---------------------------------------------------------------------------
    SIGNAL s_cap_fifo_data  : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL s_cap_fifo_wr    : STD_LOGIC;
    SIGNAL s_cap_fifo_full  : STD_LOGIC;
    SIGNAL s_cap_fifo_empty : STD_LOGIC;
    SIGNAL s_cap_fifo_dout  : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL s_cap_fifo_rd_en : STD_LOGIC;
    SIGNAL s_cap_frame_done : STD_LOGIC;
    SIGNAL s_cap_overflow   : STD_LOGIC;
    SIGNAL s_cap_en         : STD_LOGIC;
    -- Sincronizador 2FF s_mclk -> mt_pixclk_i para s_cap_en
    SIGNAL s_cap_en_sync0   : STD_LOGIC := '0';
    SIGNAL s_cap_en_pix     : STD_LOGIC := '0';

    ---------------------------------------------------------------------------
    -- FSM principal
    ---------------------------------------------------------------------------

    SIGNAL s_state      : main_state_t                                   := ST_CAM_RESET_ASSERT;
    SIGNAL s_init_cnt   : INTEGER RANGE 0 TO c_MT9V111_RESET_WAIT_CYCLES := 0;
    SIGNAL s_fill_cnt   : INTEGER RANGE 0 TO g_MT9V111_I2C_FIFO_DEPTH    := 0;
    SIGNAL cam_reset_r  : STD_LOGIC                                      := '0';
    SIGNAL s_chip_id    : STD_LOGIC_VECTOR(15 DOWNTO 0)                  := (OTHERS => '0');
    SIGNAL s_led15_r    : STD_LOGIC                                      := '0';  --! Registro del LED 15 controlado por comando

    --! Indice en c_CFG_TABLE del registro que se esta configurando
    SIGNAL s_cfg_idx    : INTEGER RANGE 0 TO c_CFG_TABLE_LEN - 1        := 0;
    --! Page del ultimo Page MAP enviado (evita reenviar si el siguiente es igual)
    SIGNAL s_cur_page   : STD_LOGIC                                      := '1';  --! Inicializado a IFP (viene de la lectura del Chip ID)

    ---------------------------------------------------------------------------
    -- Imagen multiplexada (sensor real / cam_sim)
    ---------------------------------------------------------------------------
    SIGNAL s_mt_fvalid_int : STD_LOGIC;
    SIGNAL s_mt_lvalid_int : STD_LOGIC;
    SIGNAL s_mt_data_int   : STD_LOGIC_VECTOR(c_MT9V111_DATA_BITS-1 DOWNTO 0);
    SIGNAL s_mt_pixclk_int : STD_LOGIC;

    ---------------------------------------------------------------------------
    -- cam_sim: imagen sintetica (mismo dominio mt_pixclk_i, sin reloj nuevo)
    ---------------------------------------------------------------------------
    SIGNAL s_sim_fvalid : STD_LOGIC;
    SIGNAL s_sim_lvalid : STD_LOGIC;
    SIGNAL s_sim_data   : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL s_sim_pixclk : STD_LOGIC;  --! = mt_pixclk_i (pass-through), sin conectar

    -- CMD 0x05: habilitacion de imagen sintetica - dominio s_mclk
    SIGNAL s_use_sim_image       : STD_LOGIC := '0';
    -- Sincronizador 2FF s_mclk -> mt_pixclk_i
    SIGNAL s_use_sim_image_sync0 : STD_LOGIC := '0';
    SIGNAL s_use_sim_image_pix   : STD_LOGIC := '0';

    ATTRIBUTE ASYNC_REG : string;
    ATTRIBUTE ASYNC_REG OF s_use_sim_image_sync0 : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF s_use_sim_image_pix   : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF s_cap_en_sync0        : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF s_cap_en_pix          : SIGNAL IS "TRUE";

    SIGNAL s_cmdproc_led_toggle  : STD_LOGIC;
    SIGNAL s_cmdproc_bcd         : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL s_cmdproc_cap_en      : STD_LOGIC;
    SIGNAL s_cmdproc_i2c_start   : STD_LOGIC;
    SIGNAL s_cmdproc_i2c_rw      : STD_LOGIC;
    SIGNAL s_cmdproc_i2c_num     : INTEGER RANGE 1 TO g_MT9V111_I2C_FIFO_DEPTH;
    SIGNAL s_cmdproc_i2c_addr    : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL s_cmdproc_i2c_wr_push : STD_LOGIC;
    SIGNAL s_cmdproc_i2c_wr_data : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL s_cmdproc_i2c_page    : STD_LOGIC;
    SIGNAL s_cmdproc_i2c_grant : STD_LOGIC;

    SIGNAL s_i2c_mux_rw       : STD_LOGIC;
    SIGNAL s_i2c_mux_start    : STD_LOGIC;
    SIGNAL s_i2c_mux_num_regs : INTEGER RANGE 1 TO g_MT9V111_I2C_FIFO_DEPTH;
    SIGNAL s_i2c_mux_addr_reg : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL s_i2c_mux_wr_push  : STD_LOGIC;
    SIGNAL s_i2c_mux_wr_data  : STD_LOGIC_VECTOR(15 DOWNTO 0);



BEGIN

    s_rst_final <= NOT s_locked;

    i2c_sclk_io  <= '0'       WHEN s_scl_out = '0' ELSE 'Z';
    i2c_sdata_io <= s_sda_out WHEN s_sda_oe  = '1' ELSE 'Z';
    s_sda_in     <= i2c_sdata_io;

    mt_reset_n_o <= cam_reset_r;
    mt_clk_o     <= cam_mclk_r;

    s_cap_en <= s_cmdproc_cap_en WHEN s_state = ST_FINISH ELSE '0';

    s_i2c_mux_rw       <= s_cmdproc_i2c_rw       WHEN s_state = ST_FINISH ELSE s_i2c_rw_fsm;
    s_i2c_mux_start    <= s_cmdproc_i2c_start    WHEN s_state = ST_FINISH ELSE s_i2c_start_fsm;
    s_i2c_mux_num_regs <= s_cmdproc_i2c_num      WHEN s_state = ST_FINISH ELSE s_i2c_num_regs_fsm;
    s_i2c_mux_addr_reg <= s_cmdproc_i2c_addr     WHEN s_state = ST_FINISH ELSE s_i2c_addr_reg_fsm;
    s_i2c_mux_wr_push  <= s_cmdproc_i2c_wr_push  WHEN s_state = ST_FINISH ELSE s_i2c_wr_push_fsm;
    s_i2c_mux_wr_data  <= s_cmdproc_i2c_wr_data  WHEN s_state = ST_FINISH ELSE s_i2c_wr_data_fsm;

    s_cmdproc_i2c_grant <= '1' WHEN s_state = ST_FINISH ELSE '0';
    ---------------------------------------------------------------------------
    -- FTDI - ADBUS tristate, UN ENABLE POR BIT (polaridad IOBUF.T: '0'=conduce)
    -- Cada bit con su propio enable registrado -> empaqueta en el flop de
    -- tristate de su IOB (sin LUT ni ruta larga a OBUFT.T).
    ---------------------------------------------------------------------------
    gen_ftdi_adbus : FOR i IN 0 TO c_FTDI_DATABUS_W-1 GENERATE
        ftdi_adbus_io(i) <= s_ftdi_adbus_out(i) WHEN s_ftdi_adbus_t(i) = '0' ELSE 'Z';
    END GENERATE gen_ftdi_adbus;
    s_ftdi_adbus_in <= ftdi_adbus_io;



    ---------------------------------------------------------------------------
    -- FTDI - CLKOUT via BUFG
    ---------------------------------------------------------------------------
    ftdi_clk_buf : BUFG
        PORT MAP (I => ftdi_acbus_io(c_FTDI_ACBUS_CLKOUT), O => s_ftdi_clk);

    -- Entradas de control del FTDI
    s_ftdi_rxf_n <= ftdi_acbus_io(c_FTDI_ACBUS_RXF_N);
    s_ftdi_txe_n <= ftdi_acbus_io(c_FTDI_ACBUS_TXE_N);

    -- Salidas de control del FTDI
    ftdi_acbus_io(c_FTDI_ACBUS_RXF_N)  <= 'Z';           --! Entrada - no conducir
    ftdi_acbus_io(c_FTDI_ACBUS_TXE_N)  <= 'Z';           --! Entrada - no conducir
    ftdi_acbus_io(c_FTDI_ACBUS_RD_N)   <= s_ftdi_rd_n;   --! Strobe lectura (controlado por ftdi_controller)
    ftdi_acbus_io(c_FTDI_ACBUS_WR_N)   <= s_ftdi_wr_n;   --! Strobe escritura (controlado por ftdi_controller)
    ftdi_acbus_io(c_FTDI_ACBUS_SIWU_N) <= '1';           --! Send immediate - inactivo
    ftdi_acbus_io(c_FTDI_ACBUS_OE_N)   <= s_ftdi_oe_n;   --! Output enable FTDI (controlado por ftdi_controller)
    ftdi_acbus_io(c_FTDI_ACBUS_PWRSAV) <= '1';           --! Power save - inactivo

    basys3_cat_o <= (OTHERS => '0');
    basys3_dp_o  <= '0';
    basys3_an_o  <= (OTHERS => '1');


    ---------------------------------------------------------------------------
    --! \brief FSM principal de VICON
    --!
    --! Flujo:
    --!   Reset -> Chip ID check -> configuracion 30 fps (write+verify por registro) -> captura
    --!
    --! SubFSM write+verify (estados ST_CFG_*):
    --!   Para cada entrada de c_CFG_TABLE:
    --!     1. Si la page cambia respecto a s_cur_page -> escribir Page MAP (reg 0x01)
    --!     2. Escribir el registro
    --!     3. Leer el registro (readback)
    --!     4. Comparar readback con valor esperado -> error si no coincide
    --!     5. Avanzar indice o ir a ST_FINISH
    ---------------------------------------------------------------------------
    p_fsm : PROCESS(s_mclk)
    BEGIN
        IF rising_edge(s_mclk) THEN
            IF s_rst_final = '1' THEN
                s_state         <= ST_CAM_RESET_ASSERT;
                cam_reset_r     <= '0';
                s_init_cnt      <= 0;
                s_i2c_rw_fsm        <= '0';
                s_i2c_start_fsm     <= '0';
                s_i2c_wr_push_fsm   <= '0';
                s_i2c_rd_pop_fsm    <= '0';
                s_i2c_num_regs_fsm  <= 1;
                s_i2c_addr_reg_fsm  <= (OTHERS => '0');
                s_i2c_wr_data_fsm   <= (OTHERS => '0');
                s_fill_cnt      <= 0;
                s_chip_id       <= (OTHERS => '0');
                s_cfg_idx       <= 0;
                s_cur_page      <= '1';  -- tras Chip ID quedamos en IFP
                basys3_led_o(0) <= '0';
                basys3_led_o(1) <= '0';
                s_led15_r       <= '0';  --! LED 15 apagado en reset
            ELSE
                s_i2c_start_fsm   <= '0';
                s_i2c_wr_push_fsm <= '0';
                s_i2c_rd_pop_fsm  <= '0';

                CASE s_state IS

                    -- -- Reset del sensor ------------------------------------
                    WHEN ST_CAM_RESET_ASSERT =>
                        cam_reset_r <= '0';
                        IF s_init_cnt = c_MT9V111_RESET_HOLD_CYCLES - 1 THEN
                            s_init_cnt <= 0;
                            s_state    <= ST_CAM_RESET_WAIT;
                        ELSE
                            s_init_cnt <= s_init_cnt + 1;
                        END IF;

                    WHEN ST_CAM_RESET_WAIT =>
                        cam_reset_r <= '1';
                        IF s_init_cnt = c_MT9V111_RESET_WAIT_CYCLES - 1 THEN
                            s_init_cnt <= 0;
                            s_state    <= ST_PAGE_SEL_FILL;
                        ELSE
                            s_init_cnt <= s_init_cnt + 1;
                        END IF;

                    -- -- Seleccionar IFP page para leer Chip ID --------------
                    WHEN ST_PAGE_SEL_FILL =>
                        IF s_i2c_wr_full = '0' THEN
                            s_i2c_wr_data_fsm <= x"0004";
                            s_i2c_wr_push_fsm <= '1';
                            s_state       <= ST_PAGE_SEL_START;
                        END IF;

                    WHEN ST_PAGE_SEL_START =>
                        IF s_i2c_busy = '0' THEN
                            s_i2c_rw_fsm       <= '0';
                            s_i2c_addr_reg_fsm <= x"01";
                            s_i2c_num_regs_fsm <= 1;
                            s_i2c_start_fsm    <= '1';
                            s_state        <= ST_PAGE_SEL_WAIT;
                        END IF;

                    WHEN ST_PAGE_SEL_WAIT =>
                        IF s_i2c_error = '1' THEN
                            s_state <= ST_ERROR;
                        elsif s_i2c_done = '1' THEN
                            s_state <= ST_CHIPID_RD_START;
                        END IF;

                    -- -- Lectura Chip ID ------------------------------------
                    WHEN ST_CHIPID_RD_START =>
                        IF s_i2c_busy = '0' and s_i2c_rd_empty = '1' THEN
                            s_i2c_rw_fsm       <= '1';
                            s_i2c_addr_reg_fsm <= x"FF";
                            s_i2c_num_regs_fsm <= 1;
                            s_i2c_start_fsm    <= '1';
                            s_state        <= ST_CHIPID_RD_WAIT;
                        END IF;

                    WHEN ST_CHIPID_RD_WAIT =>
                        IF s_i2c_error = '1' THEN
                            s_state <= ST_ERROR;
                        elsif s_i2c_done = '1' THEN
                            s_state <= ST_CHIPID_RD_DRAIN;
                        END IF;

                    WHEN ST_CHIPID_RD_DRAIN =>
                        IF s_i2c_rd_empty = '0' THEN
                            s_i2c_rd_pop_fsm <= '1';
                            s_chip_id    <= s_i2c_rd_data;
                            IF s_i2c_rd_data = c_MT9V111_CHIP_ID_EXPECTED THEN
                                s_cfg_idx  <= 0;
                                s_cur_page <= '1';  -- Chip ID estaba en IFP
                                s_state    <= ST_CFG_PAGE_FILL;
                            ELSE
                                s_state <= ST_ERROR;
                            END IF;
                        END IF;

                    -- ======================================================
                    -- SubFSM write+verify - itera sobre c_CFG_TABLE
                    -- ======================================================

                    -- -- 1. Cambiar page si es necesario --------------------
                    WHEN ST_CFG_PAGE_FILL =>
                        -- Si la page del registro actual coincide con la actual, saltar
                        IF c_CFG_TABLE(s_cfg_idx).page = s_cur_page THEN
                            s_state <= ST_CFG_WR_FILL;
                        elsif s_i2c_wr_full = '0' THEN
                            -- Encolar valor de page: '0'->0x0000, '1'->0x0001
                            IF c_CFG_TABLE(s_cfg_idx).page = '0' THEN
                                s_i2c_wr_data_fsm <= x"0000";
                            ELSE
                                s_i2c_wr_data_fsm <= x"0001";
                            END IF;
                            s_i2c_wr_push_fsm <= '1';
                            s_state       <= ST_CFG_PAGE_START;
                        END IF;

                    WHEN ST_CFG_PAGE_START =>
                        IF s_i2c_busy = '0' and s_i2c_rd_empty = '1' THEN
                            s_i2c_rw_fsm       <= '0';
                            s_i2c_addr_reg_fsm <= x"01";  --! Page MAP register
                            s_i2c_num_regs_fsm <= 1;
                            s_i2c_start_fsm    <= '1';
                            s_state        <= ST_CFG_PAGE_WAIT;
                        END IF;

                    WHEN ST_CFG_PAGE_WAIT =>
                        IF s_i2c_error = '1' THEN
                            s_state <= ST_ERROR;
                        elsif s_i2c_done = '1' THEN
                            s_cur_page <= c_CFG_TABLE(s_cfg_idx).page;
                            s_state    <= ST_CFG_WR_FILL;
                        END IF;

                    -- -- 2. Escribir registro -------------------------------
                    WHEN ST_CFG_WR_FILL =>
                        IF s_i2c_wr_full = '0' THEN
                            s_i2c_wr_data_fsm <= c_CFG_TABLE(s_cfg_idx).data;
                            s_i2c_wr_push_fsm <= '1';
                            s_state       <= ST_CFG_WR_START;
                        END IF;

                    WHEN ST_CFG_WR_START =>
                        IF s_i2c_busy = '0' and s_i2c_rd_empty = '1' THEN
                            s_i2c_rw_fsm       <= '0';
                            s_i2c_addr_reg_fsm <= c_CFG_TABLE(s_cfg_idx).addr;
                            s_i2c_num_regs_fsm <= 1;
                            s_i2c_start_fsm    <= '1';
                            s_state        <= ST_CFG_WR_WAIT;
                        END IF;

                    WHEN ST_CFG_WR_WAIT =>
                        IF s_i2c_error = '1' THEN
                            s_state <= ST_ERROR;
                        elsif s_i2c_done = '1' THEN
                            s_state <= ST_CFG_RD_START;
                        END IF;

                    -- -- 3. Readback (verify) -------------------------------
                    WHEN ST_CFG_RD_START =>
                        IF s_i2c_busy = '0' and s_i2c_rd_empty = '1' THEN
                            s_i2c_rw_fsm       <= '1';
                            s_i2c_addr_reg_fsm <= c_CFG_TABLE(s_cfg_idx).addr;
                            s_i2c_num_regs_fsm <= 1;
                            s_i2c_start_fsm    <= '1';
                            s_state        <= ST_CFG_RD_WAIT;
                        END IF;

                    WHEN ST_CFG_RD_WAIT =>
                        IF s_i2c_error = '1' THEN
                            s_state <= ST_ERROR;
                        elsif s_i2c_done = '1' THEN
                            s_state <= ST_CFG_RD_DRAIN;
                        END IF;

                    -- -- 4. Verificar readback ------------------------------
                    WHEN ST_CFG_RD_DRAIN =>
                        IF s_i2c_rd_empty = '0' THEN
                            s_i2c_rd_pop_fsm <= '1';
                            IF s_i2c_rd_data = c_CFG_TABLE(s_cfg_idx).data THEN
                                s_state <= ST_CFG_NEXT;
                            ELSE
                                s_state <= ST_ERROR;  --! Verify fallido
                            END IF;
                        END IF;

                    -- -- 5. Avanzar o terminar ------------------------------
                    WHEN ST_CFG_NEXT =>
                        IF s_cfg_idx = c_CFG_TABLE_LEN - 1 THEN
                            s_state <= ST_FINISH;
                        ELSE
                            s_cfg_idx <= s_cfg_idx + 1;
                            s_state   <= ST_CFG_PAGE_FILL;
                        END IF;

                    -- -- Estados finales -----------------------------------
                    WHEN ST_FINISH =>
                        basys3_led_o(0) <= '1';
                        basys3_led_o(1) <= '0';
                        -- Procesar comandos recibidos del PC
                        -- CMD 0x01 (LED): toggle LED 15 -- detectar flanco de subida
                        -- de s_cmd_valid_sync1 para evitar doble toggle
                        IF s_cmdproc_led_toggle = '1' THEN
                                s_led15_r <= NOT s_led15_r;
                            END IF;
                        s_state <= ST_FINISH;

                    WHEN ST_ERROR =>
                        basys3_led_o(0) <= '0';
                        basys3_led_o(1) <= '1';
                        s_state <= ST_ERROR;

                    WHEN OTHERS =>
                        s_state <= ST_CAM_RESET_ASSERT;

                END CASE;
            END IF;
        END IF;
    END PROCESS p_fsm;

    basys3_led_o(14 DOWNTO 2) <= basys3_sw_i(14 DOWNTO 2);  --! LEDs 14:2 reflejan switches
    basys3_led_o(15)          <= s_led15_r;                  --! LED 15 controlado por comando toggle desde PC

    ---------------------------------------------------------------------------
    -- IPs Xilinx
    ---------------------------------------------------------------------------
    u_MMCM : ENTITY work.clk_wiz_0
        PORT MAP (
            clk_in1  => basys3_clk_i,
            reset    => basys3_btn_i(c_BASYS3_BTN_CENTER),
            clk_out1 => s_mclk,
            clk_out2 => open,
            clk_out3 => cam_mclk_r,
            locked   => s_locked
        );

    u_async_fifo : ENTITY work.fifo_generator_0
        PORT MAP (
            wr_clk => s_mt_pixclk_int,
            din    => s_cap_fifo_data,
            wr_en  => s_cap_fifo_wr,
            full   => s_cap_fifo_full,
            rd_clk => s_ftdi_clk,
            dout   => s_cap_fifo_dout,
            rd_en  => s_cap_fifo_rd_en,
            empty  => s_cap_fifo_empty,
            rst    => s_rst_final
        );

    ---------------------------------------------------------------------------
    -- Modulos propios
    ---------------------------------------------------------------------------
    u_frame_capture : ENTITY work.frame_capture
        GENERIC MAP (
            g_H_RES      => c_CAP_H_RES,
            g_V_RES      => c_CAP_V_RES,
            g_CAM_FPS    => g_MT9V111_FPS,
            g_TARGET_FPS => g_MT9V111_TARGET_FPS
        )
        PORT MAP (
            pixclk_i     => s_mt_pixclk_int,
            reset_i      => s_rst_final,
            fvalid_i     => s_mt_fvalid_int,
            lvalid_i     => s_mt_lvalid_int,
            data_i       => s_mt_data_int,
            capture_en_i => s_cap_en_pix,
            fifo_data_o  => s_cap_fifo_data,
            fifo_wr_o    => s_cap_fifo_wr,
            fifo_full_i  => s_cap_fifo_full,
            frame_done_o => s_cap_frame_done,
            overflow_o   => s_cap_overflow
        );

    u_ftdi_ctrl : ENTITY work.ftdi_controller
        PORT MAP (
            clk_i        => s_ftdi_clk,
            reset_i      => s_rst_final,
            fifo_data_i  => s_cap_fifo_dout,
            fifo_empty_i => s_cap_fifo_empty,
            fifo_rd_en_o => s_cap_fifo_rd_en,
            rxf_n_i      => s_ftdi_rxf_n,       --! RXF# - dato disponible del PC
            txe_n_i      => s_ftdi_txe_n,
            rd_n_o       => s_ftdi_rd_n,         --! RD#  - strobe lectura
            wr_n_o       => s_ftdi_wr_n,
            oe_n_o       => s_ftdi_oe_n,         --! OE#  - habilita FTDI en ADBUS
            adbus_i      => s_ftdi_adbus_in,     --! ADBUS entrada (comandos del PC)
            adbus_o      => s_ftdi_adbus_out,    --! ADBUS salida  (imagen hacia PC)
            adbus_t_o    => s_ftdi_adbus_t,      --! Tristate per-bit (IOBUF.T: '0'=conduce)
            tx_active_o  => s_ftdi_tx_active,
            cmd_valid_o  => s_cmd_valid_ftdi,    --! Pulso 1 ciclo: comando decodificado listo
            cmd_type_o   => s_cmd_type_ftdi,     --! Tipo de comando
            cmd_data_o   => s_cmd_data_ftdi,     --! Payload del comando
            cmd_page_o   => s_cmd_page_ftdi,     --! Page (solo CMD I2C)
            cmd_addr_o   => s_cmd_addr_ftdi      --! Addr  (solo CMD I2C)
        );

    u_i2c : ENTITY work.i2c_master
        GENERIC MAP (
            g_CLK_FREQ_HZ => g_SYSTEM_CLK_FREQ_HZ,
            g_I2C_FREQ_HZ => g_MT9V111_I2C_FREQ_HZ,
            g_FIFO_DEPTH  => g_MT9V111_I2C_FIFO_DEPTH
        )
        PORT MAP (
            clk_i           => s_mclk,
            reset_i         => s_rst_final,
            rw_i            => s_i2c_mux_rw,
            start_i2c_i     => s_i2c_mux_start,
            num_regs_i      => s_i2c_mux_num_regs,
            addr_dev_i      => g_MT9V111_I2C_SENSOR_ADDR,
            addr_reg_i      => s_i2c_mux_addr_reg,
            wr_fifo_push_i  => s_i2c_mux_wr_push,
            wr_fifo_data_i  => s_i2c_mux_wr_data,
            wr_fifo_full_o  => s_i2c_wr_full,
            wr_fifo_empty_o => s_i2c_wr_empty,
            rd_fifo_pop_i   => s_i2c_rd_pop_fsm,
            rd_fifo_data_o  => s_i2c_rd_data,
            rd_fifo_full_o  => s_i2c_rd_full,
            rd_fifo_empty_o => s_i2c_rd_empty,
            busy_o          => s_i2c_busy,
            done_o          => s_i2c_done,
            error_o         => s_i2c_error,
            scl_o           => s_scl_out,
            sda_o           => s_sda_out,
            sda_oe_o        => s_sda_oe,
            sda_i           => s_sda_in
        );

        ---------------------------------------------------------------------------
        -- cam_sim: generador de imagen sintetica (mismo dominio mt_pixclk_i)
        ---------------------------------------------------------------------------
        u_cam_sim : ENTITY work.mt9v111_image
            GENERIC MAP (
                g_H_RES  => g_CAM_SIM_H_RES,
                g_V_RES  => g_CAM_SIM_V_RES,
                g_HBLANK => g_CAM_SIM_HBLANK,
                g_VBLANK => g_CAM_SIM_VBLANK
            )
            PORT MAP (
                clkin_i  => mt_pixclk_i,
                pixclk_o => s_sim_pixclk,
                reset_i  => s_rst_final,
                fvalid_o => s_sim_fvalid,
                lvalid_o => s_sim_lvalid,
                data_o   => s_sim_data
            );

        --! \brief Sincronizador 2FF s_mclk -> mt_pixclk_i para s_use_sim_image
        --! (mismo patron que el sincronizador de s_cap_en)
        p_sync_use_sim_image : PROCESS(mt_pixclk_i)
        BEGIN
            IF rising_edge(mt_pixclk_i) THEN
                s_use_sim_image_sync0 <= s_use_sim_image;
                s_use_sim_image_pix   <= s_use_sim_image_sync0;
            END IF;
        END PROCESS p_sync_use_sim_image;

        --! \brief Sincronizador 2FF s_mclk -> mt_pixclk_i para s_cap_en
        p_sync_cap_en : PROCESS(mt_pixclk_i)
        BEGIN
            IF rising_edge(mt_pixclk_i) THEN
                s_cap_en_sync0 <= s_cap_en;
                s_cap_en_pix   <= s_cap_en_sync0;
            END IF;
        END PROCESS p_sync_cap_en;

        -- Mux combinacional, dominio mt_pixclk_i - sensor real / cam_sim
        s_mt_fvalid_int <= s_sim_fvalid WHEN s_use_sim_image_pix = '1' ELSE mt_fvalid_i;
        s_mt_lvalid_int <= s_sim_lvalid WHEN s_use_sim_image_pix = '1' ELSE mt_lvalid_i;
        s_mt_data_int   <= s_sim_data   WHEN s_use_sim_image_pix = '1' ELSE mt_data_i;
        s_mt_pixclk_int <= mt_pixclk_i;


        u_cmd_processor : ENTITY work.cmd_processor
        GENERIC MAP (
            g_I2C_FIFO_DEPTH => g_MT9V111_I2C_FIFO_DEPTH
        )
        PORT MAP (
            ftdi_clk_i   => s_ftdi_clk,
            ftdi_reset_i => s_rst_final,
            cmd_valid_i  => s_cmd_valid_ftdi,
            cmd_type_i   => s_cmd_type_ftdi,
            cmd_data_i   => s_cmd_data_ftdi,
            cmd_page_i   => s_cmd_page_ftdi,
            cmd_addr_i   => s_cmd_addr_ftdi,

            clk_o   => s_mclk,
            reset_o => s_rst_final,

            led_toggle_o => s_cmdproc_led_toggle,
            bcd_o        => s_cmdproc_bcd,
            cap_en_cmd_o => s_cmdproc_cap_en,
            sim_img_en_o => s_use_sim_image,

            i2c_grant_i    => s_cmdproc_i2c_grant,
            i2c_busy_i     => s_i2c_busy,
            i2c_done_i     => s_i2c_done,
            i2c_error_i    => s_i2c_error,

            i2c_start_o    => s_cmdproc_i2c_start,
            i2c_rw_o       => s_cmdproc_i2c_rw,
            i2c_num_regs_o => s_cmdproc_i2c_num,
            i2c_addr_reg_o => s_cmdproc_i2c_addr,
            i2c_wr_push_o  => s_cmdproc_i2c_wr_push,
            i2c_wr_data_o  => s_cmdproc_i2c_wr_data,
            i2c_page_o     => s_cmdproc_i2c_page
        );
END ARCHITECTURE rtl;