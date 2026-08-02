--! \file i2c_controller.vhd
--! \brief Controlador I2C maestro con FIFOs de escritura y lectura.
--! \author Carlos Manuel Gomez Jimenez
--! \warning Se ha observado que a 400KHz hay problemas de funcionamiento con el I2C. Bajado a 200KHz


LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

--! \brief Entidad del controlador I2C
--! \fsm_show_actions
ENTITY i2c_master IS
    GENERIC (
        g_CLK_FREQ_HZ  : INTEGER := 100_000_000;    --! Frecuencia del reloj de sistema (Hz)
        g_I2C_FREQ_HZ  : INTEGER := 200_000;        --! Frecuencia I2C deseada (Hz); típico 100k o 400k
        g_FIFO_DEPTH   : INTEGER := 16              --! Profundidad de las FIFOs de escritura y lectura
    );
    PORT (
        clk_i   : IN STD_LOGIC;  --! Reloj de sistema
        reset_i : IN STD_LOGIC;  --! Reset síncrono activo alto

        ---------------------------------------------------------------------------
        --region: INTERFAZ DE CONTROL
        ---------------------------------------------------------------------------
        rw_i        : IN STD_LOGIC;                              --! Dirección de la transacción: '0'=escritura, '1'=lectura
        start_i2c_i : IN STD_LOGIC;                              --! Pulso de inicio de transacción (activo 1 ciclo)
        num_regs_i  : IN INTEGER RANGE 1 TO g_FIFO_DEPTH;        --! Número de registros de 16 bits a transferir
        addr_dev_i  : IN STD_LOGIC_VECTOR(6 DOWNTO 0);           --! Dirección I2C de 7 bits del esclavo
        addr_reg_i  : IN STD_LOGIC_VECTOR(7 DOWNTO 0);           --! Dirección del registro inicial a acceder
        -- endregion

        ---------------------------------------------------------------------------
        --region: WR FIFO — Usuario escribe aquí antes de lanzar una transacción Write
        ---------------------------------------------------------------------------
        wr_fifo_push_i  : IN  STD_LOGIC;                          --! Pulso para encolar dato en WR FIFO (activo 1 ciclo)
        wr_fifo_data_i  : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);      --! Dato de 16 bits a escribir en el registro del esclavo
        wr_fifo_full_o  : OUT STD_LOGIC;                          --! WR FIFO llena; no encolar más datos
        wr_fifo_empty_o : OUT STD_LOGIC;                          --! WR FIFO vacía; todos los datos han sido consumidos
        -- endregion
        
        ---------------------------------------------------------------------------
        --region: RD FIFO — Usuario lee aquí tras una transacción Read
        ---------------------------------------------------------------------------
        rd_fifo_pop_i   : IN  STD_LOGIC;                          --! Pulso para extraer dato de RD FIFO (activo 1 ciclo)
        rd_fifo_data_o  : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);      --! Dato de 16 bits leído del registro del esclavo
        rd_fifo_full_o  : OUT STD_LOGIC;                          --! RD FIFO llena; drenar antes de lanzar nueva lectura
        rd_fifo_empty_o : OUT STD_LOGIC;                          --! RD FIFO vacía; no hay datos disponibles
        -- endregion

        ---------------------------------------------------------------------------
        --region: STATUS de la transacción
        ---------------------------------------------------------------------------
        busy_o  : OUT STD_LOGIC;  --! '1' durante la transacción I2C
        done_o  : OUT STD_LOGIC;  --! Pulso de 1 ciclo al completar correctamente
        error_o : OUT STD_LOGIC;  --! '1' si hubo NACK u otro error
        --endregion

        ---------------------------------------------------------------------------
        --region: BUS I2C — señales separadas; el tristate/open-drain va en TOP
        ---------------------------------------------------------------------------
        scl_o    : OUT STD_LOGIC;  --! Valor a poner en SCL: '0'=pull-down, '1'=soltar (Z en TOP)
        sda_o    : OUT STD_LOGIC;  --! Valor a poner en SDA cuando sda_oe_o='1'
        sda_oe_o : OUT STD_LOGIC;  --! '1'=conducir SDA con sda_o,  '0'=tristate
        sda_i    : IN  STD_LOGIC   --! Valor leído del bus SDA
        --endregion
    );
END ENTITY i2c_master;

ARCHITECTURE rtl OF i2c_master IS

    ---------------------------------------------------------------------------
    -- region: CONSTANTES
    --------------------------------------------------------------------------

    -- Timing:
    ---------------------------------------------------------------------------
    CONSTANT c_CLKS_PER_PHASE : INTEGER := g_CLK_FREQ_HZ / (g_I2C_FREQ_HZ * 4); --! Ciclos de reloj por cada cuarto de periodo I2C
    --endregion

    ---------------------------------------------------------------------------
    -- region: TIPOS
    ---------------------------------------------------------------------------
    TYPE t_fifo_mem IS ARRAY (0 TO g_FIFO_DEPTH-1) OF STD_LOGIC_VECTOR(15 DOWNTO 0);
    --endregion

    
    ---------------------------------------------------------------------------
    -- SEÑALES
    ---------------------------------------------------------------------------
    ---------------------------------------------------------------------------
    -- region: WR FIFO — FIFO de escritura (usuario → bus I2C)
    ---------------------------------------------------------------------------
    SIGNAL s_wr_mem     : t_fifo_mem := (OTHERS => (OTHERS => '0'));  --! Memoria de la WR FIFO
    SIGNAL s_wr_wr_ptr  : INTEGER RANGE 0 TO g_FIFO_DEPTH-1 := 0;     --! Puntero de escritura
    SIGNAL s_wr_rd_ptr  : INTEGER RANGE 0 TO g_FIFO_DEPTH-1 := 0;     --! Puntero de lectura
    SIGNAL s_wr_count   : INTEGER RANGE 0 TO g_FIFO_DEPTH   := 0;     --! Entradas ocupadas
    SIGNAL s_wr_full    : STD_LOGIC;                                  --! FIFO llena (combinacional)
    SIGNAL s_wr_empty   : STD_LOGIC;                                  --! FIFO vacía (combinacional)
    SIGNAL s_wr_pop     : STD_LOGIC := '0';                           --! Pop interno generado por la FSM (1 ciclo)
    SIGNAL s_wr_dout    : STD_LOGIC_VECTOR(15 DOWNTO 0);              --! Cabeza de la FIFO (lectura asíncrona)
    --endregion

    ---------------------------------------------------------------------------
    -- region: RD FIFO — FIFO de lectura (bus I2C → usuario)
    ---------------------------------------------------------------------------
    SIGNAL s_rd_mem     : t_fifo_mem := (OTHERS => (OTHERS => '0'));         --! Memoria de la RD FIFO
    SIGNAL s_rd_wr_ptr  : INTEGER RANGE 0 TO g_FIFO_DEPTH-1 := 0;            --! Puntero de escritura
    SIGNAL s_rd_rd_ptr  : INTEGER RANGE 0 TO g_FIFO_DEPTH-1 := 0;            --! Puntero de lectura
    SIGNAL s_rd_count   : INTEGER RANGE 0 TO g_FIFO_DEPTH   := 0;            --! Entradas ocupadas
    SIGNAL s_rd_full    : STD_LOGIC;                                         --! FIFO llena (combinacional)
    SIGNAL s_rd_empty   : STD_LOGIC;                                         --! FIFO vacía (combinacional)
    SIGNAL s_rd_push    : STD_LOGIC := '0';                                  --! Push interno generado por la FSM (1 ciclo)
    SIGNAL s_rd_din     : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');  --! Dato a escribir en la RD FIFO
    --endregion
    
    ---------------------------------------------------------------------------
    -- region: FSM principal
    ---------------------------------------------------------------------------
    TYPE t_state IS (
        ST_IDLE,
        -- START / Repeated START
        ST_START_0, ST_START_1, ST_START_2, ST_START_3,
        -- TX byte + ACK del esclavo (RACK)
        ST_TX_0, ST_TX_1, ST_TX_2, ST_TX_3,
        ST_RACK_0, ST_RACK_1, ST_RACK_2, ST_RACK_3,
        -- RX byte + ACK del master (MACK)
        ST_RX_0, ST_RX_1, ST_RX_2, ST_RX_3,
        ST_MACK_0, ST_MACK_1, ST_MACK_2, ST_MACK_3,
        -- Puntos de decisión — secuencia WRITE
        ST_DECIDE_AFTER_ADDR_WR,
        ST_DECIDE_AFTER_REG_ADDR,
        ST_LOAD_DATA_H,           --! Espera 1 ciclo para que s_wr_word se estabilice
        ST_DECIDE_AFTER_DATA_H,
        ST_DECIDE_AFTER_DATA_L,
        ST_LOAD_NEXT_DATA_H,      --! Igual que ST_LOAD_DATA_H para registros siguientes
        -- Puntos de decisión — secuencia READ
        ST_DECIDE_AFTER_ADDR_RD,
        ST_DECIDE_AFTER_RX_H,
        ST_DECIDE_AFTER_RX_L,
        -- STOP
        ST_STOP_0, ST_STOP_1, ST_STOP_2, ST_STOP_3,
        -- Fin / Error
        ST_DONE,
        ST_ERROR_STOP,
        ST_ERROR
    );
    
    SIGNAL s_state    : t_state := ST_IDLE;                --! Estado actual de la FSM
    SIGNAL s_seq_next : t_state := ST_IDLE;                --! Estado de retorno tras TX+RACK o RX+MACK
    -- endregion

    ---------------------------------------------------------------------------
    --region: REGISTROS LATCH SEÑALES ENTRADA para estabilidad
    ---------------------------------------------------------------------------
    SIGNAL rw_r            : STD_LOGIC                        := '0';              --! Dirección capturada al inicio de la transacción
    SIGNAL addr_dev_r      : STD_LOGIC_VECTOR(6 DOWNTO 0)     := (OTHERS => '0');  --! Dirección del esclavo capturada
    SIGNAL addr_reg_r      : STD_LOGIC_VECTOR(7 DOWNTO 0)     := (OTHERS => '0');  --! Dirección del registro capturada
    SIGNAL num_regs_r      : INTEGER RANGE 1 TO g_FIFO_DEPTH  := 1;                --! Número de registros capturado
    SIGNAL s_reg_cnt       : INTEGER RANGE 0 TO g_FIFO_DEPTH  := 0;                --! Registros procesados hasta el momento
    SIGNAL s_start_rd_mode : STD_LOGIC                        := '0';              --! '1' → el próximo START será en modo lectura (Repeated START)
    --endregion

    ---------------------------------------------------------------------------
    --region: TX / RX
    ---------------------------------------------------------------------------
    SIGNAL s_tx_byte   : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');  --! Byte actual a transmitir por el bus
    SIGNAL s_rx_byte   : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');  --! Byte actual recibido del bus
    SIGNAL s_rx_high   : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');  --! Byte alto recibido, pendiente de combinarse con el bajo
    SIGNAL s_bit_cnt   : INTEGER RANGE 0 TO 7         := 7;                --! Índice del bit en curso (MSB=7)
    SIGNAL s_wr_word   : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0'); --! Dato de 16 bits capturado de la WR FIFO
    SIGNAL s_send_nack : STD_LOGIC                    := '0';              --! '1' → MACK enviará NACK (último byte de lectura)
    --endregion

    ---------------------------------------------------------------------------
    -- region: Generador de fase
    ---------------------------------------------------------------------------
    SIGNAL s_phase_cnt  : INTEGER RANGE 0 TO c_CLKS_PER_PHASE-1 := 0;   --! Contador de ciclos dentro de la fase actual
    SIGNAL s_phase_tick : STD_LOGIC                             := '0'; --! Pulso activo cada cuarto de periodo I2C
    --endregion

    ---------------------------------------------------------------------------
    -- region: Señales internas del bus I2C
    ---------------------------------------------------------------------------
    SIGNAL scl_r     : STD_LOGIC := '1';  --! Registro del valor de SCL
    SIGNAL sda_out_r : STD_LOGIC := '1';  --! Registro del valor a conducir en SDA
    SIGNAL s_sda_oe  : STD_LOGIC := '1';  --! '1'=conducir SDA,  '0'=tristate
    --endregion

    ---------------------------------------------------------------------------
    -- Salidas de estado — registros internos que alimentan las salidas
    ---------------------------------------------------------------------------
    SIGNAL s_busy  : STD_LOGIC := '0';  --! Registro interno de busy_o
    SIGNAL s_done  : STD_LOGIC := '0';  --! Registro interno de done_o
    SIGNAL s_error : STD_LOGIC := '0';  --! Registro interno de error_o


    attribute fsm_encoding : STRING;
    attribute fsm_encoding OF s_state : SIGNAL IS "auto";


    -- SIGNAL debug_state_slv : STD_LOGIC_VECTOR(4 DOWNTO 0);  --! ILA: estado FSM codificado

    BEGIN
        -- region: ILA DESHABILITADO para leer estados internos del controlador
        -- with s_state select debug_state_slv <=
        -- "00000" WHEN ST_IDLE,
        -- "00001" WHEN ST_START_0,
        -- "00010" WHEN ST_START_1,
        -- "00011" WHEN ST_START_2,
        -- "00100" WHEN ST_START_3,
        -- "00101" WHEN ST_TX_0,
        -- "00110" WHEN ST_TX_1,
        -- "00111" WHEN ST_TX_2,
        -- "01000" WHEN ST_TX_3,
        -- "01001" WHEN ST_RACK_0,
        -- "01010" WHEN ST_RACK_1,
        -- "01011" WHEN ST_RACK_2,
        -- "01100" WHEN ST_RACK_3,
        -- "01101" WHEN ST_RX_0,
        -- "01110" WHEN ST_RX_1,
        -- "01111" WHEN ST_RX_2,
        -- "10000" WHEN ST_RX_3,
        -- "10001" WHEN ST_MACK_0,
        -- "10010" WHEN ST_MACK_1,
        -- "10011" WHEN ST_MACK_2,
        -- "10100" WHEN ST_MACK_3,
        -- "10101" WHEN ST_DECIDE_AFTER_ADDR_WR,
        -- "10110" WHEN ST_DECIDE_AFTER_REG_ADDR,
        -- "10111" WHEN ST_LOAD_DATA_H,
        -- "11000" WHEN ST_DECIDE_AFTER_DATA_H,
        -- "11001" WHEN ST_DECIDE_AFTER_DATA_L,
        -- "11010" WHEN ST_LOAD_NEXT_DATA_H,
        -- "11011" WHEN ST_DECIDE_AFTER_ADDR_RD,
        -- "11100" WHEN ST_DECIDE_AFTER_RX_H,
        -- "11101" WHEN ST_DECIDE_AFTER_RX_L,
        -- "11110" WHEN ST_STOP_0,
        -- "11111" WHEN ST_STOP_1,
        -- "11111" WHEN ST_STOP_2,  -- se solapan pero son poco críticos
        -- "11111" WHEN ST_DONE,
        -- "11111" WHEN ST_ERROR_STOP,
        -- "11111" WHEN ST_ERROR,
        -- "11111" WHEN OTHERS;

        -- u_ila_i2c : ENTITY work.ila_1
        -- PORT map (
        --     clk       => clk_i,
        --     probe0(0) => scl_r,
        --     probe1(0) => sda_out_r,
        --     probe2(0) => sda_i,
        --     probe3    => addr_reg_r,
        --     probe4(0) => rw_r,
        --     probe5(0) => s_busy,
        --     probe6(0) => s_sda_oe,
        --     probe7(0) => s_error,
        --     probe8(0) => s_start_rd_mode,
        --     probe9 => debug_state_slv
        -- );
        --endregion

        ---------------------------------------------------------------------------
        -- WR FIFO
        ---------------------------------------------------------------------------
        s_wr_full       <= '1' WHEN s_wr_count = g_FIFO_DEPTH ELSE '0';
        s_wr_empty      <= '1' WHEN s_wr_count = 0            ELSE '0';
        wr_fifo_full_o  <= s_wr_full;
        wr_fifo_empty_o <= s_wr_empty;
        s_wr_dout       <= s_wr_mem(s_wr_rd_ptr); -- s_wr_dout es combinacional sobre s_wr_rd_ptr (lectura asíncrona).

        p_wr_fifo : PROCESS(clk_i)
            VARIABLE v_do_push : BOOLEAN;
            VARIABLE v_do_pop  : BOOLEAN;
            BEGIN
                IF rising_edge(clk_i) THEN
                    IF reset_i = '1' THEN
                        s_wr_wr_ptr <= 0;
                        s_wr_rd_ptr <= 0;
                        s_wr_count  <= 0;
                    ELSE
                        v_do_push := (wr_fifo_push_i = '1') AND (s_wr_full  = '0');
                        v_do_pop  := (s_wr_pop       = '1') AND (s_wr_empty = '0');
                        IF v_do_push THEN
                            s_wr_mem(s_wr_wr_ptr) <= wr_fifo_data_i;
                            s_wr_wr_ptr <= (s_wr_wr_ptr + 1) MOD g_FIFO_DEPTH;
                        END IF;
                        IF v_do_pop THEN
                            s_wr_rd_ptr <= (s_wr_rd_ptr + 1) MOD g_FIFO_DEPTH;
                        END IF;
                        IF    v_do_push AND NOT v_do_pop THEN s_wr_count <= s_wr_count + 1;
                        elsif v_do_pop  AND NOT v_do_push THEN s_wr_count <= s_wr_count - 1;
                        END IF;
                    END IF;
                END IF;
        END PROCESS p_wr_fifo;

        ---------------------------------------------------------------------------
        -- RD FIFO
        ---------------------------------------------------------------------------
        s_rd_full       <= '1' WHEN s_rd_count = g_FIFO_DEPTH ELSE '0';
        s_rd_empty      <= '1' WHEN s_rd_count = 0            ELSE '0';
        rd_fifo_full_o  <= s_rd_full;
        rd_fifo_empty_o <= s_rd_empty;
        rd_fifo_data_o  <= s_rd_mem(s_rd_rd_ptr);

        p_rd_fifo : PROCESS(clk_i)
            VARIABLE v_do_push : BOOLEAN;
            VARIABLE v_do_pop  : BOOLEAN;
            BEGIN
                IF rising_edge(clk_i) THEN
                    IF reset_i = '1' THEN
                        s_rd_wr_ptr <= 0;
                        s_rd_rd_ptr <= 0;
                        s_rd_count  <= 0;
                    ELSE
                        v_do_push := (s_rd_push     = '1') AND (s_rd_full  = '0');
                        v_do_pop  := (rd_fifo_pop_i = '1') AND (s_rd_empty = '0');
                        IF v_do_push THEN
                            s_rd_mem(s_rd_wr_ptr) <= s_rd_din;
                            s_rd_wr_ptr <= (s_rd_wr_ptr + 1) MOD g_FIFO_DEPTH;
                        END IF;
                        IF v_do_pop THEN
                            s_rd_rd_ptr <= (s_rd_rd_ptr + 1) MOD g_FIFO_DEPTH;
                        END IF;
                        IF    v_do_push AND NOT v_do_pop THEN s_rd_count <= s_rd_count + 1;
                        elsif v_do_pop  AND NOT v_do_push THEN s_rd_count <= s_rd_count - 1;
                        END IF;
                    END IF;
                END IF;
        END PROCESS p_rd_fifo;

        ---------------------------------------------------------------------------
        -- Generador de fase
        -- Genera un pulso (s_phase_tick) cada c_CLKS_PER_PHASE ciclos.
        -- Cada fase corresponde a un cuarto de periodo I2C.
        ---------------------------------------------------------------------------
        p_phase : PROCESS(clk_i)
            BEGIN
                IF rising_edge(clk_i) THEN
                    IF reset_i = '1' THEN
                        s_phase_cnt  <= 0;
                        s_phase_tick <= '0';
                    elsif s_phase_cnt = c_CLKS_PER_PHASE - 1 THEN
                        s_phase_cnt  <= 0;
                        s_phase_tick <= '1';
                    ELSE
                        s_phase_cnt  <= s_phase_cnt + 1;
                        s_phase_tick <= '0';
                    END IF;
                END IF;
        END PROCESS p_phase;

        ---------------------------------------------------------------------------
        -- FSM principal
        --
        -- Cada estado de bus (ST_TX_x, ST_RX_x, etc.) espera un s_phase_tick
        -- para avanzar, garantizando el timing I2C correcto.
        -- Los estados de decisión (ST_DECIDE_*) no esperan s_phase_tick.
        ---------------------------------------------------------------------------
        p_fsm : PROCESS(clk_i)
            BEGIN
                IF rising_edge(clk_i) THEN
                    IF reset_i = '1' THEN
                        s_state         <= ST_IDLE;
                        s_seq_next      <= ST_IDLE;
                        s_busy          <= '0';
                        s_done          <= '0';
                        s_error         <= '0';
                        scl_r           <= '1';
                        sda_out_r       <= '1';
                        s_sda_oe        <= '1';
                        s_wr_pop        <= '0';
                        s_rd_push       <= '0';
                        s_rd_din        <= (OTHERS => '0');
                        s_tx_byte       <= (OTHERS => '0');
                        s_rx_byte       <= (OTHERS => '0');
                        s_rx_high       <= (OTHERS => '0');
                        s_wr_word       <= (OTHERS => '0');
                        s_bit_cnt       <= 7;
                        s_reg_cnt       <= 0;
                        s_send_nack     <= '0';
                        s_start_rd_mode <= '0';
                        rw_r            <= '0';
                        addr_dev_r      <= (OTHERS => '0');
                        addr_reg_r      <= (OTHERS => '0');
                        num_regs_r      <= 1;
                    ELSE
                        -- Pulsos de un ciclo por defecto
                        s_wr_pop  <= '0';
                        s_rd_push <= '0';
                        s_done    <= '0';

                        CASE s_state IS

                            -----------------------------------------------------------
                            WHEN ST_IDLE =>
                                scl_r       <= '1';
                                sda_out_r   <= '1';
                                s_sda_oe    <= '1';
                                s_busy      <= '0';
                                s_error     <= '0';
                                IF start_i2c_i = '1' THEN
                                    IF s_rd_empty = '0' THEN
                                        null;   -- RD FIFO no vaciada: bloquear
                                    ELSE
                                        rw_r            <= rw_i;
                                        addr_dev_r      <= addr_dev_i;
                                        addr_reg_r      <= addr_reg_i;
                                        num_regs_r      <= num_regs_i;
                                        s_reg_cnt       <= 0;
                                        s_start_rd_mode <= '0';
                                        s_busy          <= '1';
                                        s_state         <= ST_START_0;
                                    END IF;
                                END IF;

                            -----------------------------------------------------------
                            -- START / Repeated START
                            -- Secuencia: SCL alto → SDA baja → SCL baja
                            -----------------------------------------------------------
                            WHEN ST_START_0 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0'; sda_out_r <= '1'; s_sda_oe <= '1';
                                    s_state <= ST_START_1;
                                END IF;

                            WHEN ST_START_1 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '1'; s_state <= ST_START_2;
                                END IF;

                            WHEN ST_START_2 =>
                                IF s_phase_tick = '1' THEN
                                    sda_out_r <= '0';   -- SDA baja con SCL alto → condición START
                                    s_state     <= ST_START_3;
                                END IF;

                            WHEN ST_START_3 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r   <= '0';
                                    s_bit_cnt <= 7;
                                    IF s_start_rd_mode = '0' THEN
                                        s_tx_byte  <= addr_dev_r & '0';   -- ADDR + Write
                                        s_seq_next <= ST_DECIDE_AFTER_ADDR_WR;
                                    ELSE
                                        s_tx_byte  <= addr_dev_r & '1';   -- ADDR + Read
                                        s_seq_next <= ST_DECIDE_AFTER_ADDR_RD;
                                    END IF;
                                    s_state <= ST_TX_0;
                                END IF;

                            -----------------------------------------------------------
                            -- TX byte reutilizable
                            -- Precargar antes de entrar: s_tx_byte, s_bit_cnt=7, s_seq_next
                            -- Envía bit a bit de MSB a LSB, luego va a ST_RACK_0
                            -----------------------------------------------------------
                            WHEN ST_TX_0 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r       <= '0';
                                    s_sda_oe    <= '1';
                                    sda_out_r   <= s_tx_byte(s_bit_cnt);
                                    s_state     <= ST_TX_1;
                                END IF;

                            WHEN ST_TX_1 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '1'; s_state <= ST_TX_2;
                                END IF;

                            WHEN ST_TX_2 =>
                                IF s_phase_tick = '1' THEN
                                    s_state <= ST_TX_3;
                                END IF;

                            WHEN ST_TX_3 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0';
                                    IF s_bit_cnt = 0 THEN
                                        s_bit_cnt <= 7;
                                        s_state   <= ST_RACK_0;
                                    ELSE
                                        s_bit_cnt <= s_bit_cnt - 1;
                                        s_state   <= ST_TX_0;
                                    END IF;
                                END IF;

                            -----------------------------------------------------------
                            -- RACK: ACK del esclavo
                            -- El master suelta SDA (s_sda_oe='0') y lee el bus.
                            -- SDA='0' → ACK,  SDA='1' → NACK → error
                            -----------------------------------------------------------
                            WHEN ST_RACK_0 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0'; s_sda_oe <= '0'; s_state <= ST_RACK_1;
                                END IF;

                            WHEN ST_RACK_1 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '1'; s_state <= ST_RACK_2;
                                END IF;

                            WHEN ST_RACK_2 =>
                                IF s_phase_tick = '1' THEN
                                    IF sda_i = '1' THEN
                                        s_state <= ST_ERROR_STOP;   -- NACK recibido
                                    ELSE
                                        s_state <= ST_RACK_3;       -- ACK recibido
                                    END IF;
                                END IF;

                            WHEN ST_RACK_3 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0'; s_state <= s_seq_next;
                                END IF;

                            -----------------------------------------------------------
                            -- Decisión WRITE: tras ACK de ADDR_WR → enviar REG_ADDR
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_ADDR_WR =>
                                s_tx_byte  <= addr_reg_r;
                                s_bit_cnt  <= 7;
                                s_seq_next <= ST_DECIDE_AFTER_REG_ADDR;
                                s_state    <= ST_TX_0;

                            -----------------------------------------------------------
                            -- Decisión: tras ACK de REG_ADDR
                            --   Write → capturar dato de WR FIFO
                            --   Read  → Repeated START en modo lectura
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_REG_ADDR =>
                                IF rw_r = '0' THEN
                                    IF s_wr_empty = '0' THEN
                                        s_wr_word <= s_wr_dout;  -- capturar (s_wr_dout es combinacional)
                                        s_wr_pop  <= '1';        -- avanzar puntero en el flanco siguiente
                                        s_state   <= ST_LOAD_DATA_H;
                                    END IF;
                                    -- FIFO vacía: esperar en este estado
                                ELSE
                                    s_start_rd_mode <= '1';
                                    s_state         <= ST_START_0;
                                END IF;

                            -----------------------------------------------------------
                            -- ST_LOAD_DATA_H: s_wr_word estable → cargar byte alto en TX
                            -----------------------------------------------------------
                            WHEN ST_LOAD_DATA_H =>
                                s_tx_byte  <= s_wr_word(15 DOWNTO 8);
                                s_bit_cnt  <= 7;
                                s_seq_next <= ST_DECIDE_AFTER_DATA_H;
                                s_state    <= ST_TX_0;

                            -----------------------------------------------------------
                            -- Decisión: tras ACK de DATA_H → enviar byte bajo
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_DATA_H =>
                                s_tx_byte  <= s_wr_word(7 DOWNTO 0);
                                s_bit_cnt  <= 7;
                                s_seq_next <= ST_DECIDE_AFTER_DATA_L;
                                s_state    <= ST_TX_0;

                            -----------------------------------------------------------
                            -- Decisión: tras ACK de DATA_L → ¿más registros?
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_DATA_L =>
                                s_reg_cnt <= s_reg_cnt + 1;
                                IF s_reg_cnt + 1 = num_regs_r THEN
                                    s_state <= ST_STOP_0;         -- todos escritos
                                ELSE
                                    IF s_wr_empty = '0' THEN
                                        s_wr_word <= s_wr_dout;
                                        s_wr_pop  <= '1';
                                        s_state   <= ST_LOAD_NEXT_DATA_H;
                                    END IF;
                                    -- FIFO vacía: esperar aquí
                                END IF;

                            -----------------------------------------------------------
                            -- ST_LOAD_NEXT_DATA_H: igual que ST_LOAD_DATA_H
                            -- (estado separado para claridad; mismo comportamiento)
                            -----------------------------------------------------------
                            WHEN ST_LOAD_NEXT_DATA_H =>
                                s_tx_byte  <= s_wr_word(15 DOWNTO 8);
                                s_bit_cnt  <= 7;
                                s_seq_next <= ST_DECIDE_AFTER_DATA_H;
                                s_state    <= ST_TX_0;

                            -----------------------------------------------------------
                            -- Decisión READ: tras ACK de ADDR_RD → recibir DATA_H
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_ADDR_RD =>
                                s_send_nack <= '0';
                                s_bit_cnt   <= 7;
                                s_seq_next  <= ST_DECIDE_AFTER_RX_H;
                                s_state     <= ST_RX_0;

                            -----------------------------------------------------------
                            -- Decisión: tras MACK de DATA_H → recibir DATA_L
                            -- Activar NACK si este es el último registro
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_RX_H =>
                                s_rx_high <= s_rx_byte;
                                IF s_reg_cnt + 1 = num_regs_r THEN
                                    s_send_nack <= '1';   -- último registro → NACK en DATA_L
                                ELSE
                                    s_send_nack <= '0';
                                END IF;
                                s_bit_cnt  <= 7;
                                s_seq_next <= ST_DECIDE_AFTER_RX_L;
                                s_state    <= ST_RX_0;

                            -----------------------------------------------------------
                            -- Decisión: tras MACK de DATA_L → push RD FIFO, ¿más?
                            -----------------------------------------------------------
                            WHEN ST_DECIDE_AFTER_RX_L =>
                                IF s_rd_full = '0' THEN
                                    s_rd_din  <= s_rx_high & s_rx_byte;
                                    s_rd_push <= '1';
                                    s_reg_cnt <= s_reg_cnt + 1;
                                    IF s_reg_cnt + 1 = num_regs_r THEN
                                        s_state <= ST_STOP_0;     -- todos leídos
                                    ELSE
                                        s_send_nack <= '0';
                                        s_bit_cnt   <= 7;
                                        s_seq_next  <= ST_DECIDE_AFTER_RX_H;
                                        s_state     <= ST_RX_0;
                                    END IF;
                                ELSE
                                    s_state <= ST_ERROR_STOP;     -- RD FIFO llena
                                END IF;

                            -----------------------------------------------------------
                            -- RX byte reutilizable
                            -- Precargar antes de entrar: s_send_nack, s_bit_cnt=7, s_seq_next
                            -- Captura bit a bit de MSB a LSB, luego va a ST_MACK_0
                            -----------------------------------------------------------
                            WHEN ST_RX_0 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0'; s_sda_oe <= '0'; s_state <= ST_RX_1;
                                END IF;

                            WHEN ST_RX_1 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '1'; s_state <= ST_RX_2;
                                END IF;

                            WHEN ST_RX_2 =>
                                IF s_phase_tick = '1' THEN
                                    s_rx_byte(s_bit_cnt) <= sda_i; s_state <= ST_RX_3;
                                END IF;

                            WHEN ST_RX_3 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0';
                                    IF s_bit_cnt = 0 THEN
                                        s_bit_cnt <= 7;
                                        s_state   <= ST_MACK_0;
                                    ELSE
                                        s_bit_cnt <= s_bit_cnt - 1;
                                        s_state   <= ST_RX_0;
                                    END IF;
                                END IF;

                            -----------------------------------------------------------
                            -- MACK: master envía ACK ('0') o NACK ('1') según s_send_nack
                            -----------------------------------------------------------
                            WHEN ST_MACK_0 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r       <= '0';
                                    s_sda_oe    <= '1';
                                    sda_out_r   <= s_send_nack;
                                    s_state     <= ST_MACK_1;
                                END IF;

                            WHEN ST_MACK_1 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '1'; s_state <= ST_MACK_2;
                                END IF;

                            WHEN ST_MACK_2 =>
                                IF s_phase_tick = '1' THEN
                                    s_state <= ST_MACK_3;
                                END IF;

                            WHEN ST_MACK_3 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0'; s_state <= s_seq_next;
                                END IF;

                            -----------------------------------------------------------
                            -- STOP: SDA sube mientras SCL está alto
                            -----------------------------------------------------------
                            WHEN ST_STOP_0 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '0'; sda_out_r <= '0'; s_sda_oe <= '1';
                                    s_state <= ST_STOP_1;
                                END IF;

                            WHEN ST_STOP_1 =>
                                IF s_phase_tick = '1' THEN
                                    scl_r <= '1'; s_state <= ST_STOP_2;
                                END IF;

                            WHEN ST_STOP_2 =>
                                IF s_phase_tick = '1' THEN
                                    sda_out_r   <= '1';   -- SDA sube con SCL alto → condición STOP
                                    s_state     <= ST_STOP_3;
                                END IF;

                            WHEN ST_STOP_3 =>
                                IF s_phase_tick = '1' THEN
                                    s_state <= ST_DONE;
                                END IF;

                            -----------------------------------------------------------
                            WHEN ST_DONE =>
                                s_done  <= '1';
                                s_busy  <= '0';
                                s_state <= ST_IDLE;

                            WHEN ST_ERROR_STOP =>
                                s_error <= '1';
                                s_state <= ST_STOP_0;   -- liberar bus antes de volver a IDLE

                            WHEN ST_ERROR =>
                                s_error <= '1';
                                s_busy  <= '0';
                                s_state <= ST_IDLE;

                            WHEN OTHERS =>
                                s_state <= ST_IDLE;

                        END CASE;
                    END IF;
                END IF;
        END PROCESS p_fsm;

        ---------------------------------------------------------------------------
        -- Asignación de salidas
        ---------------------------------------------------------------------------
        scl_o    <= scl_r;
        sda_o    <= sda_out_r;
        sda_oe_o <= s_sda_oe;

        busy_o  <= s_busy;
        done_o  <= s_done;
        error_o <= s_error;

END ARCHITECTURE rtl;
