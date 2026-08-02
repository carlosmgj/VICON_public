--! \file ftdi_agent.vhd
--! \brief Agente de simulacion del chip FT232H en modo Synchronous FIFO 245 con host PC asincrono.
--!
--! Para inyectar comandos PC->FPGA, edita la tabla c_CMD_TABLE mas abajo.
--! Protocolo de comandos:
--!   General (4 bytes): [0xCC] [CMD] [DATA_H] [DATA_L]
--!   I2C     (6 bytes): [0xCC] [0x03] [PAGE] [ADDR] [DATA_H] [DATA_L]
--!
--! CMD:
--!   0x01 -> LEDs        DATA[15:0] = mascara 16 LEDs
--!   0x02 -> BCD 7seg    DATA[15:0] = 4 digitos BCD
--!   0x03 -> Reg I2C     PAGE, ADDR, DATA[15:0]
--!   0x04 -> Control cap DATA[0] = capture_en
--! \author Carlos Manuel Gomez Jimenez

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

LIBRARY work;
USE work.config_pkg.ALL;
USE work.sim_utils_pkg.ALL;

LIBRARY uvvm_util;
CONTEXT uvvm_util.uvvm_util_context;

ENTITY ftdi_agent IS
    GENERIC (
        g_LOG_FILE                : STRING  := "ftdi_rx_log.txt";
        g_TX_FIFO_DEPTH           : INTEGER := 512;
        g_TXE_BUSY_THRESHOLD      : INTEGER := 480;
        g_TXE_BUSY_CYCLES         : INTEGER := 1;
        g_PC_READ_START_THRESHOLD : INTEGER := 100;
        g_PC_READ_PERIOD          : TIME    := 100 ns;
        --! Retardo CLKOUT->dato valido en lectura (Tabla 4.1, t5 "CLKOUT to
        --! read DATA valid"). Modela el clock-to-out del FT232H para que el
        --! dato no este disponible en el mismo flanco, sino t_CO despues.
        --! Debe ser < periodo de CLKOUT (16.67 ns).
        g_FTDI_TCO                : TIME    := 9 ns
    );
    PORT (
        acbus_io : INOUT STD_LOGIC_VECTOR(c_FTDI_CONTROLBUS_W-1 DOWNTO 0);
        adbus_io : INOUT STD_LOGIC_VECTOR(c_FTDI_DATABUS_W-1    DOWNTO 0)
    );
END ENTITY ftdi_agent;

ARCHITECTURE sim OF ftdi_agent IS

    CONSTANT c_FTDI_CLK_PERIOD : TIME := 1 sec / 60_000_000;

    CONSTANT c_FRAME_MARKER_0 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"AA";
    CONSTANT c_FRAME_MARKER_1 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"55";
    CONSTANT c_FRAME_MARKER_2 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"AA";
    CONSTANT c_FRAME_MARKER_3 : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"55";

    CONSTANT c_CMD_SYNC : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"CC";
    CONSTANT c_CMD_LED  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"01";
    CONSTANT c_CMD_BCD  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"02";
    CONSTANT c_CMD_I2C  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"03";
    CONSTANT c_CMD_CAP  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"04";

    TYPE t_byte_array IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(7 DOWNTO 0);

    ---------------------------------------------------------------------------
    -- TABLA DE COMANDOS A INYECTAR (PC -> FPGA)
    --
    -- Cada fila es un comando ya serializado en bytes (longitud VARIABLE).
    -- El primer campo es la longitud real (4 o 6); el resto del ARRAY
    -- se rellena con ceros y se ignora.
    ---------------------------------------------------------------------------
    TYPE t_cmd_entry IS RECORD
        len   : INTEGER;
        bytes : t_byte_array(0 TO 5);
    END RECORD;
    TYPE t_cmd_table IS ARRAY (NATURAL RANGE <>) OF t_cmd_entry;

    CONSTANT c_CMD_TABLE : t_cmd_table := (
        0 => (len => 4, bytes => (x"CC", x"01", x"00", x"00", x"00", x"00")),  -- LED toggle
        1 => (len => 4, bytes => (x"CC", x"01", x"00", x"00", x"00", x"00")),  -- LED toggle
        2 => (len => 4, bytes => (x"CC", x"01", x"00", x"00", x"00", x"00")),  -- LED toggle
        3 => (len => 6, bytes => (x"CC", x"03", x"01", x"37", x"00", x"80")),  -- I2C write
        4 => (len => 4, bytes => (x"CC", x"04", x"00", x"00", x"00", x"00")),  -- CAP off
        5 => (len => 4, bytes => (x"CC", x"04", x"00", x"01", x"00", x"00")),  -- CAP on
        6 => (len => 4, bytes => (x"CC", x"05", x"00", x"00", x"00", x"00")),  -- SIM off
        7 => (len => 4, bytes => (x"CC", x"05", x"00", x"01", x"00", x"00"))   -- SIM on
    );

    CONSTANT c_CMD_START_DELAY : TIME := 350 us;  --! Espera antes del primer comando
    CONSTANT c_CMD_GAP         : TIME := 200 us;   --! Espera entre comandos

    -- FIFO RX real (FPGA->PC): ARRAY circular con punteros wr/rd
    SIGNAL s_rx_fifo      : t_byte_array(0 TO g_TX_FIFO_DEPTH-1) := (OTHERS => (OTHERS => '0'));
    SIGNAL s_rx_fifo_wr   : INTEGER RANGE 0 TO g_TX_FIFO_DEPTH-1 := 0;
    SIGNAL s_rx_fifo_rd   : INTEGER RANGE 0 TO g_TX_FIFO_DEPTH-1 := 0;
    SIGNAL s_rx_fifo_level: INTEGER RANGE 0 TO g_TX_FIFO_DEPTH   := 0;
    SIGNAL s_rx_fifo_push : STD_LOGIC := '0';
    SIGNAL s_rx_fifo_din  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_rx_fifo_pop  : STD_LOGIC := '0';
    SIGNAL s_rx_fifo_dout : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_rx_fifo_empty: STD_LOGIC := '1';
    SIGNAL s_rx_fifo_full : STD_LOGIC := '0';

    SIGNAL s_tx_fifo_dout : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    SIGNAL s_clkout : STD_LOGIC := '0';
    SIGNAL s_txe_n  : STD_LOGIC := '0';
    SIGNAL s_rxf_n  : STD_LOGIC := '1';

BEGIN

    acbus_io                      <= (OTHERS => 'Z');
    acbus_io(c_FTDI_ACBUS_CLKOUT) <= s_clkout;
    acbus_io(c_FTDI_ACBUS_TXE_N)  <= s_txe_n;
    acbus_io(c_FTDI_ACBUS_RXF_N)  <= s_rxf_n;

    -- El FT232H conduce el bus de datos solo con OE#='0' y RXF#='0' (hay dato).
    adbus_io <= s_tx_fifo_dout
                WHEN (To_X01(acbus_io(c_FTDI_ACBUS_OE_N))  = '0' AND
                      To_X01(acbus_io(c_FTDI_ACBUS_RXF_N)) = '0')
                ELSE (OTHERS => 'Z');

    s_rx_fifo_empty <= '1' WHEN s_rx_fifo_level = 0               ELSE '0';
    s_rx_fifo_full  <= '1' WHEN s_rx_fifo_level = g_TX_FIFO_DEPTH ELSE '0';
    s_rx_fifo_dout  <= s_rx_fifo(s_rx_fifo_rd);

    ---------------------------------------------------------------------------
    -- p_rx_fifo_ctrl: gestiona punteros y nivel de la FIFO RX (FPGA->PC)
    --
    -- (CORREGIDO: el contador de nivel ahora trata correctamente el caso de
    --  push y pop simultaneos -> el nivel queda IGUAL, no incrementado.)
    ---------------------------------------------------------------------------
    p_rx_fifo_ctrl : PROCESS
        VARIABLE v_push : BOOLEAN;
        VARIABLE v_pop  : BOOLEAN;
    BEGIN
        LOOP
            WAIT UNTIL rising_edge(s_clkout);

            v_push := (s_rx_fifo_push = '1' AND s_rx_fifo_full  = '0');
            v_pop  := (s_rx_fifo_pop  = '1' AND s_rx_fifo_empty = '0');

            IF v_push THEN
                s_rx_fifo(s_rx_fifo_wr) <= s_rx_fifo_din;
                IF s_rx_fifo_wr = g_TX_FIFO_DEPTH-1 THEN
                    s_rx_fifo_wr <= 0;
                ELSE
                    s_rx_fifo_wr <= s_rx_fifo_wr + 1;
                END IF;
            END IF;

            IF v_pop THEN
                IF s_rx_fifo_rd = g_TX_FIFO_DEPTH-1 THEN
                    s_rx_fifo_rd <= 0;
                ELSE
                    s_rx_fifo_rd <= s_rx_fifo_rd + 1;
                END IF;
            END IF;

            IF v_push AND NOT v_pop THEN
                s_rx_fifo_level <= s_rx_fifo_level + 1;
            ELSIF v_pop AND NOT v_push THEN
                s_rx_fifo_level <= s_rx_fifo_level - 1;
            END IF;
        END LOOP;
    END PROCESS p_rx_fifo_ctrl;

    ---------------------------------------------------------------------------
    -- p_clkout: Generador de CLKOUT 60 MHz
    ---------------------------------------------------------------------------
    p_clkout : PROCESS
    BEGIN
        LOOP
            s_clkout <= '0'; WAIT FOR c_FTDI_CLK_PERIOD / 2;
            s_clkout <= '1'; WAIT FOR c_FTDI_CLK_PERIOD / 2;
        END LOOP;
    END PROCESS p_clkout;

    ---------------------------------------------------------------------------
    -- p_txe: Control de TXE# segun nivel de la FIFO RX
    ---------------------------------------------------------------------------
    p_txe : PROCESS
    BEGIN
        s_txe_n <= '0';
        IF g_TXE_BUSY_CYCLES = 0 THEN
            log(ID_SEQUENCER, "TXE# fijo a '0' - proteccion desactivada", "FTDI_TXE");
            WAIT;
        END IF;
        LOOP
            WAIT UNTIL s_rx_fifo_level >= g_TXE_BUSY_THRESHOLD;
            s_txe_n <= '1';
            log(ID_SEQUENCER, "TXE# -> '1' (buffer lleno, nivel=" &
                to_string(s_rx_fifo_level) & ")", "FTDI_TXE");
            FOR i IN 1 TO g_TXE_BUSY_CYCLES LOOP
                WAIT UNTIL rising_edge(s_clkout);
            END LOOP;
            WAIT UNTIL s_rx_fifo_level < (g_TXE_BUSY_THRESHOLD - 32);
            s_txe_n <= '0';
            log(ID_SEQUENCER, "TXE# -> '0' (buffer liberado)", "FTDI_TXE");
        END LOOP;
    END PROCESS p_txe;

    ---------------------------------------------------------------------------
    -- p_rx: Captura bytes FPGA->PC y los mete en la FIFO RX
    --
    -- (CORREGIDO: FT245-Sync captura un byte en CADA rising_edge con WR#='0'
    --  y TXE#='0'. La version anterior exigia WR#='0' en dos flancos
    --  consecutivos (v_wrn_prev), lo que perdia el PRIMER byte de cada rafaga.)
    ---------------------------------------------------------------------------
    p_rx : PROCESS
    BEGIN
        s_rx_fifo_push <= '0';
        s_rx_fifo_din  <= (OTHERS => '0');
        LOOP
            WAIT UNTIL rising_edge(s_clkout);
            IF To_X01(acbus_io(c_FTDI_ACBUS_WR_N)) = '0' AND
               To_X01(s_txe_n) = '0' THEN
                -- El dato lo lanza la FPGA en el falling_edge previo, por lo que
                -- esta estable ~media periodo antes de este rising_edge.
                s_rx_fifo_din  <= To_X01(adbus_io);
                s_rx_fifo_push <= '1';
            ELSE
                s_rx_fifo_push <= '0';
            END IF;
        END LOOP;
    END PROCESS p_rx;

    ---------------------------------------------------------------------------
    -- p_pc_host_driver: Simula el PC leyendo la FIFO RX y logueando bytes
    ---------------------------------------------------------------------------
    p_pc_host_driver : PROCESS
        VARIABLE v_byte_cnt   : INTEGER := 0;
        VARIABLE v_frame_cnt  : INTEGER := 0;
        VARIABLE v_frame_bytes: INTEGER := 0;
        VARIABLE v_line       : line;
        VARIABLE v_byte       : STD_LOGIC_VECTOR(7 DOWNTO 0);
        VARIABLE v_buf0       : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
        VARIABLE v_buf1       : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
        VARIABLE v_buf2       : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
        VARIABLE v_buf3       : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
        VARIABLE v_in_frame   : boolean := false;
        FILE     f_log        : text;
    BEGIN
        s_rx_fifo_pop <= '0';
        file_open(f_log, g_LOG_FILE, write_mode);
        write(v_line, STRING'("[FTDI PC HOST] Inicio de log"));
        writeline(f_log, v_line);
        log(ID_SEQUENCER, "PC Host driver iniciado (Modo: Solo monitorizacion)", "FTDI_PC");

        LOOP
            WAIT UNTIL s_rx_fifo_level >= g_PC_READ_START_THRESHOLD;
            log(ID_SEQUENCER, "PC HOST: umbral alcanzado (" &
                to_string(s_rx_fifo_level) & " bytes) - leyendo", "FTDI_PC");

            WHILE s_rx_fifo_empty = '0' LOOP

                v_byte     := s_rx_fifo_dout;
                v_byte_cnt := v_byte_cnt + 1;

                s_rx_fifo_pop <= '1';
                WAIT UNTIL rising_edge(s_clkout);
                s_rx_fifo_pop <= '0';

                v_buf0 := v_buf1; v_buf1 := v_buf2;
                v_buf2 := v_buf3; v_buf3 := v_byte;

                IF v_buf0 = c_FRAME_MARKER_0 AND v_buf1 = c_FRAME_MARKER_1 AND
                   v_buf2 = c_FRAME_MARKER_2 AND v_buf3 = c_FRAME_MARKER_3 THEN

                    IF v_in_frame THEN
                        log(ID_SEQUENCER,
                            "====== FRAME " & to_string(v_frame_cnt) &
                            " END - " & to_string(v_frame_bytes) &
                            " bytes recibidos ======", "FTDI_PC");
                        write(v_line, STRING'("[FTDI PC HOST] FIN FRAME " &
                            INTEGER'image(v_frame_cnt) &
                            " bytes=" & INTEGER'image(v_frame_bytes)));
                        writeline(f_log, v_line);
                    END IF;

                    v_frame_cnt   := v_frame_cnt + 1;
                    v_frame_bytes := 0;
                    v_in_frame    := true;

                    log(ID_SEQUENCER,
                        "====== FRAME " & to_string(v_frame_cnt) &
                        " START (AA 55 AA 55) ======", "FTDI_PC");
                    write(v_line, STRING'("[FTDI PC HOST] INICIO FRAME " &
                        INTEGER'image(v_frame_cnt)));
                    writeline(f_log, v_line);

                elsif v_in_frame THEN
                    v_frame_bytes := v_frame_bytes + 1;
                END IF;

                log(ID_SEQUENCER, "PC HOST: Recibido Byte #" & to_string(v_byte_cnt) &
                    " = 0x" & int_to_hex_str(to_integer(unsigned(v_byte)), 2), "FTDI_PC");

                write(v_line, STRING'("[" & TIME'image(now) &
                    "] Byte #" & INTEGER'image(v_byte_cnt) &
                    " : 0x" & int_to_hex_str(to_integer(unsigned(v_byte)), 2)));
                writeline(f_log, v_line);

                WAIT FOR g_PC_READ_PERIOD;

            END LOOP;

            log(ID_SEQUENCER, "PC HOST: buffer vaciado - volviendo a idle", "FTDI_PC");

        END LOOP;

        file_close(f_log);
        WAIT;
    END PROCESS p_pc_host_driver;

    ---------------------------------------------------------------------------
    -- p_tx_inject: Inyeccion de comandos PC->FPGA segun c_CMD_TABLE
    --
    -- Protocolo rafaga continua:
    --   RXF#='0' indica que hay datos. En cuanto OE#='0' el agente conduce el
    --   byte actual. En CADA rising_edge con OE#='0' Y RD#='0' el byte actual
    --   se consume y el agente presenta el siguiente t_CO despues del flanco
    --   (modela t5 "CLKOUT to read DATA valid"). RXF# sube cuando se han
    --   consumido los 'len' bytes del comando.
    ---------------------------------------------------------------------------
    p_tx_inject : PROCESS
        VARIABLE v_idx   : INTEGER;
        VARIABLE v_first : BOOLEAN;   --! salta el 1er flanco RD# (pipeline t5+insercion)
    BEGIN
        s_rxf_n        <= '1';
        s_tx_fifo_dout <= (OTHERS => '0');

        IF c_CMD_TABLE'length = 0 THEN
            log(ID_SEQUENCER, "TX inject: tabla de comandos vacia, RXF# permanece a '1'", "FTDI_TX");
            WAIT;
        END IF;

        WAIT FOR c_CMD_START_DELAY;

        FOR c IN c_CMD_TABLE'RANGE LOOP

            log(ID_SEQUENCER, "TX inject: enviando comando " & to_string(c) &
                " (" & to_string(c_CMD_TABLE(c).len) & " bytes) CMD=0x" &
                int_to_hex_str(to_integer(unsigned(c_CMD_TABLE(c).bytes(1))), 2),
                "FTDI_TX");

            -- Preparar byte[0] (ya conducido en cuanto OE#='0') y activar RXF#.
            v_idx          := 0;
            v_first        := true;
            s_tx_fifo_dout <= c_CMD_TABLE(c).bytes(0);
            s_rxf_n        <= '0';

            -- El FT232H real entrega el dato un ciclo mas tarde (t5 ~9 ns +
            -- insercion de reloj): el controlador descarta el PRIMER flanco con
            -- RD#='0' (estado ST_RD0) y lee byte[0]=SYNC en el SEGUNDO (ST_RD1).
            -- Por eso aqui mantenemos byte[0] en el primer flanco y empezamos a
            -- avanzar a partir del segundo. (Sin esto, sim y hardware no
            -- coinciden: en sim se leeria CMD donde el HW lee SYNC.)
            WHILE v_idx < c_CMD_TABLE(c).len LOOP
                WAIT UNTIL rising_edge(s_clkout);

                IF To_X01(acbus_io(c_FTDI_ACBUS_OE_N)) = '0' AND
                   To_X01(acbus_io(c_FTDI_ACBUS_RD_N)) = '0' THEN

                    IF v_first THEN
                        -- Primer flanco RD#='0' = ciclo de pipeline (ST_RD0).
                        -- No avanzar: byte[0] sigue en el bus para que el
                        -- controlador lo lea en el proximo flanco (ST_RD1).
                        v_first := false;
                    ELSE
                        log(ID_SEQUENCER, "TX inject: byte[" & to_string(v_idx) &
                            "] = 0x" & int_to_hex_str(
                                to_integer(unsigned(c_CMD_TABLE(c).bytes(v_idx))), 2),
                            "FTDI_TX");

                        v_idx := v_idx + 1;
                        IF v_idx < c_CMD_TABLE(c).len THEN
                            -- Presentar siguiente byte t_CO despues del flanco;
                            -- el controlador lo capturara en el proximo rising_edge.
                            s_tx_fifo_dout <= c_CMD_TABLE(c).bytes(v_idx) AFTER g_FTDI_TCO;
                        ELSE
                            -- Ultimo byte consumido: subir RXF# para que el
                            -- controlador no intente leer mas.
                            s_rxf_n        <= '1';
                            s_tx_fifo_dout <= (OTHERS => '0');
                        END IF;
                    END IF;
                END IF;

            END LOOP;

            log(ID_SEQUENCER, "TX inject: comando " & to_string(c) & " completado", "FTDI_TX");

            IF c < c_CMD_TABLE'high THEN
                WAIT FOR c_CMD_GAP;
            END IF;

        END LOOP;

        log(ID_SEQUENCER, "TX inject: todos los comandos enviados", "FTDI_TX");
        WAIT;
    END PROCESS p_tx_inject;

END ARCHITECTURE sim;
