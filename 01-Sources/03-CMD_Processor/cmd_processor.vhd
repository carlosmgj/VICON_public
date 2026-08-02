--! \file cmd_processor.vhd
--! \brief Procesador de comandos PC->FPGA decodificados por ftdi_controller.
--!
--! Recibe el comando ya decodificado (cmd_valid/cmd_type/cmd_data/cmd_page/cmd_addr)
--! en el dominio ftdi_clk, realiza el CDC hacia clk_o, y expone salidas listas
--! para usar en el TOP:
--!
--!   CMD 0x01 (LED)  -> toggle de led_toggle_o (pulso 1 ciclo en clk_o)
--!   CMD 0x02 (BCD)  -> bcd_o = cmd_data (registrado)
--!   CMD 0x03 (I2C)  -> lanza una transaccion de escritura en i2c_master
--!   CMD 0x04 (CAP)  -> cap_en_o = cmd_data(0) (registrado)
--!   CMD 0x05 (SIM)  -> sim_img_en_o = cmd_data(0) (registrado, 1=imagen sintetica)
--!
--! El acceso al bus I2C solo se activa cuando i2c_grant_i='1' (tipicamente
--! s_state = ST_FINISH en el TOP). Si llega un comando I2C antes, se descarta.
--!
--! CDC: 3 flip-flops para cmd_valid (deteccion de flanco), 2 para el payload.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

LIBRARY work;
USE work.config_pkg.ALL;

--! \fsm_show_actions
ENTITY cmd_processor IS
    GENERIC (
        g_I2C_FIFO_DEPTH : INTEGER := c_MT9V111_I2C_FIFO_DEPTH
    );
    PORT (
        ---------------------------------------------------------------------------
        -- Dominio ftdi_clk: comando decodificado por ftdi_controller
        ---------------------------------------------------------------------------
        ftdi_clk_i      : IN STD_LOGIC;
        ftdi_reset_i    : IN STD_LOGIC;
        cmd_valid_i     : IN STD_LOGIC;
        cmd_type_i      : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        cmd_data_i      : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
        cmd_page_i      : IN STD_LOGIC;
        cmd_addr_i      : IN STD_LOGIC_VECTOR(7 DOWNTO 0);

        ---------------------------------------------------------------------------
        -- Dominio clk_o (s_mclk): salidas para el TOP
        ---------------------------------------------------------------------------
        clk_o   : IN STD_LOGIC;
        reset_o : IN STD_LOGIC;

        -- CMD 0x01 (LED): pulso de 1 ciclo cuando llega un toggle
        led_toggle_o : OUT STD_LOGIC;

        -- CMD 0x02 (BCD): valor registrado
        bcd_o : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);

        -- CMD 0x04 (CAP): valor registrado (capture enable)
        cap_en_cmd_o : OUT STD_LOGIC;

        -- CMD 0x05 (SIM): valor registrado (1 = usar imagen sintética cam_sim)
        sim_img_en_o : OUT STD_LOGIC;

        -- Interfaz con i2c_master (solo activa cuando i2c_grant_i='1')
        i2c_grant_i    : IN  STD_LOGIC;
        i2c_busy_i     : IN  STD_LOGIC;
        i2c_done_i     : IN  STD_LOGIC;
        i2c_error_i    : IN  STD_LOGIC;

        i2c_start_o    : OUT STD_LOGIC;
        i2c_rw_o       : OUT STD_LOGIC;
        i2c_num_regs_o : OUT INTEGER RANGE 1 TO g_I2C_FIFO_DEPTH;
        i2c_addr_reg_o : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        i2c_wr_push_o  : OUT STD_LOGIC;
        i2c_wr_data_o  : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
        i2c_page_o     : OUT STD_LOGIC  --! Page del comando I2C (gestion de Page Map delegada al llamador)
    );
END ENTITY cmd_processor;

ARCHITECTURE rtl OF cmd_processor IS

    CONSTANT c_CMD_LED : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"01";
    CONSTANT c_CMD_BCD : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"02";
    CONSTANT c_CMD_I2C : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"03";
    CONSTANT c_CMD_CAP : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"04";
    CONSTANT c_CMD_SIM : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"05";

    ---------------------------------------------------------------------------
    -- CDC: ftdi_clk -> clk_o
    ---------------------------------------------------------------------------
    SIGNAL s_valid_sync0 : STD_LOGIC := '0';
    SIGNAL s_valid_sync1 : STD_LOGIC := '0';
    SIGNAL s_valid_sync2 : STD_LOGIC := '0';
    SIGNAL s_type_sync0  : STD_LOGIC_VECTOR(7 DOWNTO 0)  := (OTHERS => '0');
    SIGNAL s_type_sync1  : STD_LOGIC_VECTOR(7 DOWNTO 0)  := (OTHERS => '0');
    SIGNAL s_data_sync0  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_data_sync1  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_page_sync0  : STD_LOGIC := '0';
    SIGNAL s_page_sync1  : STD_LOGIC := '0';
    SIGNAL s_addr_sync0  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_addr_sync1  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    ATTRIBUTE ASYNC_REG : string;
    ATTRIBUTE ASYNC_REG OF s_valid_sync0 : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF s_valid_sync1 : SIGNAL IS "TRUE";

    -- Pulso de comando nuevo en dominio clk_o (flanco de subida de sync1)
    SIGNAL s_cmd_pulse : STD_LOGIC;

    ---------------------------------------------------------------------------
    -- FSM de ejecucion I2C
    ---------------------------------------------------------------------------
    type t_exec_state IS (
        ST_EXEC_IDLE,
        ST_EXEC_I2C_FILL,
        ST_EXEC_I2C_START,
        ST_EXEC_I2C_WAIT
    );
    SIGNAL s_exec_state : t_exec_state := ST_EXEC_IDLE;

    -- Comando I2C latcheado mientras se ejecuta (puede tardar varios ciclos)
    SIGNAL s_i2c_pending : STD_LOGIC := '0';
    SIGNAL s_i2c_page_r  : STD_LOGIC := '0';
    SIGNAL s_i2c_addr_r  : STD_LOGIC_VECTOR(7 DOWNTO 0)  := (OTHERS => '0');
    SIGNAL s_i2c_data_r  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');

    -- Registros de salida
    SIGNAL s_led_toggle_r : STD_LOGIC := '0';
    SIGNAL s_bcd_r        : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_cap_en_r     : STD_LOGIC := '1';
    SIGNAL s_sim_en_r     : STD_LOGIC := '1';

BEGIN

    led_toggle_o <= s_led_toggle_r;
    bcd_o        <= s_bcd_r;
    cap_en_cmd_o <= s_cap_en_r;
    sim_img_en_o <= s_sim_en_r;
    i2c_page_o   <= s_i2c_page_r;

    s_cmd_pulse <= s_valid_sync1 AND NOT s_valid_sync2;

    ---------------------------------------------------------------------------
    -- p_cdc: sincronizadores 2FF (3 para cmd_valid -> deteccion de flanco)
    ---------------------------------------------------------------------------
    p_cdc : PROCESS(clk_o)
    BEGIN
        IF rising_edge(clk_o) THEN
            IF reset_o = '1' THEN
                s_valid_sync0 <= '0'; s_valid_sync1 <= '0'; s_valid_sync2 <= '0';
                s_type_sync0  <= (OTHERS => '0'); s_type_sync1 <= (OTHERS => '0');
                s_data_sync0  <= (OTHERS => '0'); s_data_sync1 <= (OTHERS => '0');
                s_page_sync0  <= '0'; s_page_sync1 <= '0';
                s_addr_sync0  <= (OTHERS => '0'); s_addr_sync1 <= (OTHERS => '0');
            ELSE
                s_valid_sync0 <= cmd_valid_i;
                s_valid_sync1 <= s_valid_sync0;
                s_valid_sync2 <= s_valid_sync1;
                s_type_sync0  <= cmd_type_i;
                s_type_sync1  <= s_type_sync0;
                s_data_sync0  <= cmd_data_i;
                s_data_sync1  <= s_data_sync0;
                s_page_sync0  <= cmd_page_i;
                s_page_sync1  <= s_page_sync0;
                s_addr_sync0  <= cmd_addr_i;
                s_addr_sync1  <= s_addr_sync0;
            END IF;
        END IF;
    END PROCESS p_cdc;


    -- u_ila: ENTITY work.ila_0
    --     PORT MAP (
    --     clk        => clk_o,
    --     probe0(0)  => s_led_toggle_r,
    --     probe1     => s_bcd_r,
    --     probe2(0)  => s_cap_en_r,
    --     probe3(0)  => s_sim_en_r,
    --     probe4(0)  => s_i2c_pending,
    --     probe5(0)  => s_i2c_page_r,
    --     probe6     => s_i2c_addr_r,
    --     probe7     => s_data_sync1 ,
    --     probe8(0)  => s_valid_sync1,
    --     probe9(0)  => s_valid_sync2,
    --     probe10(0) => s_cmd_pulse,
    --     probe11    => s_type_sync1
    -- );

    ---------------------------------------------------------------------------
    -- p_dispatch: en el flanco de un comando nuevo, actualizar salidas simples
    -- (LED toggle, BCD, CAP) y latchear el comando I2C si corresponde
    ---------------------------------------------------------------------------
    p_dispatch : PROCESS(clk_o)
    BEGIN
        IF rising_edge(clk_o) THEN
            IF reset_o = '1' THEN
                s_led_toggle_r <= '0';
                s_bcd_r        <= (OTHERS => '0');
                s_cap_en_r     <= '1';
                s_sim_en_r     <= '1';
                s_i2c_pending  <= '0';
                s_i2c_page_r   <= '0';
                s_i2c_addr_r   <= (OTHERS => '0');
                s_i2c_data_r   <= (OTHERS => '0');
            ELSE
                s_led_toggle_r <= '0';  -- pulso de 1 ciclo

                IF s_cmd_pulse = '1' THEN
                    CASE s_type_sync1 IS

                        WHEN c_CMD_LED =>
                            s_led_toggle_r <= '1';

                        WHEN c_CMD_BCD =>
                            s_bcd_r <= s_data_sync1;

                        WHEN c_CMD_CAP =>
                            s_cap_en_r <= s_data_sync1(0);

                        WHEN c_CMD_SIM =>
                            s_sim_en_r <= s_data_sync1(0);

                        WHEN c_CMD_I2C =>
                            IF i2c_grant_i = '1' AND s_i2c_pending = '0' THEN
                                s_i2c_pending <= '1';
                                s_i2c_page_r  <= s_page_sync1;
                                s_i2c_addr_r  <= s_addr_sync1;
                                s_i2c_data_r  <= s_data_sync1;
                            END IF;
                            -- Si i2c_grant_i='0' o ya hay uno pendiente, se descarta

                        WHEN OTHERS => NULL;

                    END CASE;
                END IF;

                -- Limpiar el pending cuando la FSM de ejecucion termina
                IF s_exec_state = ST_EXEC_I2C_WAIT AND
                   (i2c_done_i = '1' OR i2c_error_i = '1') THEN
                    s_i2c_pending <= '0';
                END IF;
            END IF;
        END IF;
    END PROCESS p_dispatch;

    ---------------------------------------------------------------------------
    -- p_exec: FSM de escritura I2C (solo CMD 0x03)
    ---------------------------------------------------------------------------
    p_exec : PROCESS(clk_o)
    BEGIN
        IF rising_edge(clk_o) THEN
            IF reset_o = '1' THEN
                s_exec_state   <= ST_EXEC_IDLE;
                i2c_start_o    <= '0';
                i2c_rw_o       <= '0';
                i2c_num_regs_o <= 1;
                i2c_addr_reg_o <= (OTHERS => '0');
                i2c_wr_push_o  <= '0';
                i2c_wr_data_o  <= (OTHERS => '0');
            ELSE
                i2c_start_o   <= '0';
                i2c_wr_push_o <= '0';

                CASE s_exec_state IS

                    WHEN ST_EXEC_IDLE =>
                        IF s_i2c_pending = '1' THEN
                            s_exec_state <= ST_EXEC_I2C_FILL;
                        END IF;

                    -- Encolar el dato a escribir
                    WHEN ST_EXEC_I2C_FILL =>
                        i2c_wr_data_o <= s_i2c_data_r;
                        i2c_wr_push_o <= '1';
                        s_exec_state  <= ST_EXEC_I2C_START;

                    -- Lanzar escritura cuando el master este libre
                    WHEN ST_EXEC_I2C_START =>
                        IF i2c_busy_i = '0' THEN
                            i2c_rw_o       <= '0';  -- escritura
                            i2c_addr_reg_o <= s_i2c_addr_r;
                            i2c_num_regs_o <= 1;
                            i2c_start_o    <= '1';
                            s_exec_state   <= ST_EXEC_I2C_WAIT;
                        END IF;

                    WHEN ST_EXEC_I2C_WAIT =>
                        IF i2c_done_i = '1' OR i2c_error_i = '1' THEN
                            s_exec_state <= ST_EXEC_IDLE;
                        END IF;

                    WHEN OTHERS =>
                        s_exec_state <= ST_EXEC_IDLE;

                END CASE;
            END IF;
        END IF;
    END PROCESS p_exec;

END ARCHITECTURE rtl;