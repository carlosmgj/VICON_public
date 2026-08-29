--! \file ftdi_controller.vhd
--! \brief Controlador FT232H modo Synchronous FIFO 245 (FT245-Sync).
--!
--! Reloj: clk_i = CLKOUT (60 MHz) generado por el FT232H. El controlador usa
--! dos dominios derivados del mismo CLKOUT:
--!   - TX (FPGA->PC): se lanza DATA/WR# en FALLING_EDGE. El FT232H los muestrea
--!     en su flanco de SUBIDA (setup t12/t14 >= 7.5 ns, Tabla 4.1). En esta
--!     placa CLKOUT entra por un pin NO clock-capable (~5.6 ns de insercion);
--!     con esa insercion, el lanzamiento en bajada coloca el dato en el ojo de
--!     muestreo del FT232H con amplio margen (~15 ns). Lanzar en subida dejaria
--!     ~7 ns (< 7.5) y fallaria. (Con CLKOUT en un pin clock-capable de baja
--!     insercion la eleccion correcta seria la contraria: subida + IOB.)
--!   - RX (PC->FPGA): se captura adbus_i en rising_edge. El dato de lectura
--!     llega t5 (<=9 ns, Tabla 4.1) despues del flanco, asi que se muestrea
--!     en el SIGUIENTE flanco (pipeline natural de 1 ciclo).
--!
--! ---------------------------------------------------------------------------
--! Protocolo de LECTURA (FT245-Sync, Figura 4.4 / Tabla 4.1 del datasheet):
--!   1) OE# debe ir a '0' >= 1 ciclo de CLKOUT ANTES que RD# (evita contienda
--!      mientras el FT232H toma el bus). Estados PRE -> PRE2 -> OE -> OE2.
--!   2) En cuanto OE#='0' el FT232H YA conduce byte[0] en el bus.
--!   3) El dato de lectura llega t5 (~9 ns, Tabla 4.1) DESPUES del flanco y,
--!      con la insercion de reloj de la placa, se captura un ciclo mas tarde.
--!      Por eso hay un ciclo de PIPELINE vacio (RD0 no lee) y se empieza a
--!      leer en RD1:
--!        ST_RD0 pipeline (rd_n recien a '0', NO leer)
--!        ST_RD1 lee byte[0] = SYNC
--!        ST_RD2 lee byte[1] = CMD
--!        ST_RD3 lee byte[2] = DATA_H (gral) / PAGE (I2C)
--!        ST_RD4 lee byte[3] = DATA_L (gral, ULTIMO) / ADDR (I2C)
--!        ST_RD5 lee byte[4] = DATA_H (I2C)
--!        ST_RD6 lee byte[5] = DATA_L (I2C, ULTIMO)
--!      (IMPORTANTE: no eliminar el ciclo RD0. Sin el, se lee CMD donde se
--!       espera SYNC y se descartan todos los comandos en hardware real.)
--!   4) Turnaround de salida: en el ultimo RDx se sueltan RD#/OE# (FT232H deja
--!      el bus) pero la FPGA NO conduce todavia; se espera un ciclo (RELEASE)
--!      antes de volver a conducir el bus => sin contienda.
--!
--! Trama:
--!   General (4 bytes): [0xCC][CMD][DATA_H][DATA_L]
--!   I2C     (6 bytes): [0xCC][0x03][PAGE][ADDR][DATA_H][DATA_L]
--!
--! \author Carlos Manuel Gomez Jimenez

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY ftdi_controller IS
    PORT (
        clk_i   : IN STD_LOGIC;
        reset_i : IN STD_LOGIC;

        fifo_data_i  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
        fifo_empty_i : IN  STD_LOGIC;
        fifo_rd_en_o : OUT STD_LOGIC;

        rxf_n_i  : IN    STD_LOGIC;
        txe_n_i  : IN    STD_LOGIC;
        rd_n_o   : OUT   STD_LOGIC;
        wr_n_o   : OUT   STD_LOGIC;
        oe_n_o   : OUT   STD_LOGIC;
        adbus_i  : IN    STD_LOGIC_VECTOR(7 DOWNTO 0);
        adbus_o  : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);
        --! Control de tristate del bus, UNO POR BIT y en polaridad del IOBUF.T:
        --!   '0' = la FPGA conduce ese bit ; '1' = Hi-Z (lo conduce el FT232H).
        --! Cada bit sale de su propio FF -> empaqueta en el flop de tristate de
        --! su IOB (sin LUT ni routing largo). En el TOP, conecta cada
        --! adbus_t_o(i) directamente al T del IOBUF de ftdi_adbus_io(i).
        adbus_t_o : OUT  STD_LOGIC_VECTOR(7 DOWNTO 0);

        tx_active_o : OUT STD_LOGIC;

        cmd_valid_o : OUT STD_LOGIC;
        cmd_type_o  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        cmd_data_o  : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
        cmd_page_o  : OUT STD_LOGIC;
        cmd_addr_o  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
    );
END ENTITY ftdi_controller;

ARCHITECTURE rtl OF ftdi_controller IS

    CONSTANT c_CMD_SYNC : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"CC";
    CONSTANT c_CMD_I2C  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"03";

    SIGNAL s_rx_active : STD_LOGIC := '0';

    ---------------------------------------------------------------------------
    -- TX (falling_edge)
    ---------------------------------------------------------------------------
    SIGNAL s_wr_n      : STD_LOGIC := '1';
    SIGNAL s_data_r    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_fifo_rd   : STD_LOGIC := '0';
    SIGNAL s_tx_active : STD_LOGIC := '0';
    SIGNAL s_adbus_oe  : STD_LOGIC := '1';

    ---------------------------------------------------------------------------
    -- RX (rising_edge)
    ---------------------------------------------------------------------------
    TYPE t_rx_state IS (
        ST_RX_IDLE,
        ST_RX_PRE,      --! adbus_oe='0': la FPGA pide soltar el bus
        ST_RX_PRE2,     --! dead-cycle: el enable registrado (s_adbus_oe_q) ya
                        --!  esta a '0' antes de que OE# baje (sin contienda)
        ST_RX_OE,       --! oe_n='0': el FT232H toma el bus (conduce byte[0])
        ST_RX_OE2,      --! rd_n='0': OE# lleva >=1 ciclo bajo antes de RD#
        ST_RD0,         --! rd_n='0' recien activo: pipeline, NO leer (1 ciclo)
        ST_RD1,         --! lee byte[0]=SYNC
        ST_RD2,         --! lee byte[1]=CMD
        ST_RD3,         --! lee byte[2]=DATA_H / PAGE
        ST_RD4,         --! lee byte[3]=DATA_L(gral,ULT) / ADDR(I2C)
        ST_RD5,         --! lee byte[4]=DATA_H (I2C)
        ST_RD6,         --! lee byte[5]=DATA_L (I2C, ULTIMO)
        ST_RX_RELEASE,  --! FT232H ya solto el bus; ahora la FPGA puede conducir
        ST_RX_RELEASE2, --! margen
        ST_RX_EXEC      --! emite cmd_valid_o
    );

    SIGNAL s_rx_state    : t_rx_state := ST_RX_IDLE;
    SIGNAL s_oe_n        : STD_LOGIC := '1';
    SIGNAL s_rd_n        : STD_LOGIC := '1';
    SIGNAL s_adbus_oe_rx : STD_LOGIC := '1';
    SIGNAL s_cmd_valid_r : STD_LOGIC := '0';
    SIGNAL s_cmd_type    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_cmd_page    : STD_LOGIC := '0';
    SIGNAL s_cmd_addr    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_cmd_dh      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_cmd_dl      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL s_is_i2c      : STD_LOGIC := '0'; --! latcheado en ST_RD1
    SIGNAL s_abort       : STD_LOGIC := '0'; --! flag de aborto (SYNC fallido)

    --! Tristate del bus de datos, REGISTRADO bit a bit en polaridad IOBUF.T
    --! ('0'=conduce, '1'=Hi-Z). Al ser un vector de FFs directos (sin LUT),
    --! cada bit empaqueta en el flop de tristate de su IOB -> camino corto a
    --! OBUFT.T. Es la version registrada e invertida del mux de direccion.
    SIGNAL s_adbus_t  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    -- Senal de debug para el ILA (13 estados -> 4 bits)
    SIGNAL s_dbg_rx_state : STD_LOGIC_VECTOR(3 DOWNTO 0);

BEGIN

    s_dbg_rx_state <= STD_LOGIC_VECTOR(TO_UNSIGNED(t_rx_state'POS(s_rx_state), 4));

    fifo_rd_en_o <= s_fifo_rd;
    adbus_o      <= s_data_r;
    wr_n_o       <= s_wr_n;
    oe_n_o       <= s_oe_n;
    rd_n_o       <= s_rd_n;
    adbus_t_o    <= s_adbus_t;
    tx_active_o  <= s_tx_active;
    cmd_valid_o  <= s_cmd_valid_r;

    -- u_ila_ftdi : ENTITY work.ila_ftdi
    -- PORT MAP (
        -- clk        => clk_i,
        -- probe0     => adbus_i,          -- 8 bits: lo que lee la FPGA del FT232H
        -- probe1(0)  => rxf_n_i,          -- RXF#
        -- probe2(0)  => txe_n_i,          -- TXE#
        -- probe3(0)  => s_rd_n,           -- RD# interno
        -- probe4(0)  => s_oe_n,           -- OE# interno
        -- probe5(0)  => s_wr_n,           -- WR# interno
        -- probe6(0)  => s_adbus_oe_rx,    -- direccion del tristate RX
        -- probe7(0)  => s_rx_active,      -- RX ocupando el bus
        -- probe8(0)  => s_cmd_valid_r,    -- pulso cmd_valid
        -- probe9     => s_cmd_type,       -- tipo comando decodificado (8 bits)
        -- probe10    => s_dbg_rx_state    -- estado FSM RX (4 bits)
    -- );

    ---------------------------------------------------------------------------
    -- p_tx: TX (FPGA->PC) — lanzado en FALLING_EDGE.
    --
    -- El FT232H muestrea WR#/DATA en su flanco de SUBIDA. En esta placa CLKOUT
    -- entra por un pin NO clock-capable (P17) con ~5.6 ns de insercion de reloj;
    -- con esa insercion, lanzar en flanco de BAJADA coloca el dato en el ojo de
    -- muestreo del FT232H con amplio margen (~15 ns), mientras que lanzarlo en
    -- flanco de subida deja ~7 ns (< 7.5 ns) y falla. Por eso aqui es falling.
    -- (Si algun dia CLKOUT entra por un pin clock-capable con baja insercion,
    --  el flanco de subida + IOB seria lo correcto.)
    --
    -- NOTA: asume FIFO de tipo First-Word-Fall-Through (fifo_data_i ya valido
    -- cuando fifo_empty_i='0'); s_fifo_rd actua como "pop/ack" del byte usado.
    -- Si la FIFO tiene 1 ciclo de latencia de lectura, hay que registrar
    -- fifo_data_i un ciclo antes (no es el caso por defecto en Xilinx FWFT).
    ---------------------------------------------------------------------------
    p_tx : PROCESS(clk_i)
    BEGIN
        IF falling_edge(clk_i) THEN
            IF reset_i = '1' THEN
                s_wr_n      <= '1';
                s_data_r    <= (OTHERS => '0');
                s_fifo_rd   <= '0';
                s_tx_active <= '0';
                s_adbus_oe  <= '1';
            ELSE
                s_fifo_rd <= '0';
                s_wr_n    <= '1';
                IF s_rx_active = '0' THEN
                    s_adbus_oe <= '1';
                    IF fifo_empty_i = '0' AND txe_n_i = '0' THEN
                        s_data_r    <= fifo_data_i;
                        s_wr_n      <= '0';
                        s_fifo_rd   <= '1';
                        s_tx_active <= '1';
                    ELSE
                        s_tx_active <= '0';
                    END IF;
                ELSE
                    -- Durante RX el bus lo gobierna s_adbus_oe_rx (ver mux).
                    s_adbus_oe  <= '0';
                    s_tx_active <= '0';
                END IF;
            END IF;
        END IF;
    END PROCESS p_tx;

    ---------------------------------------------------------------------------
    -- p_rx: RX comandos (PC->FPGA) — capturado en rising_edge
    ---------------------------------------------------------------------------
    p_rx : PROCESS(clk_i)
    BEGIN
        IF rising_edge(clk_i) THEN
            IF reset_i = '1' THEN
                s_rx_state    <= ST_RX_IDLE;
                s_rx_active   <= '0';
                s_oe_n        <= '1';
                s_rd_n        <= '1';
                s_adbus_oe_rx <= '1';
                s_cmd_valid_r <= '0';
                s_cmd_type    <= (OTHERS => '0');
                s_cmd_page    <= '0';
                s_cmd_addr    <= (OTHERS => '0');
                s_cmd_dh      <= (OTHERS => '0');
                s_cmd_dl      <= (OTHERS => '0');
                s_is_i2c      <= '0';
                s_abort       <= '0';
                cmd_type_o    <= (OTHERS => '0');
                cmd_data_o    <= (OTHERS => '0');
                cmd_page_o    <= '0';
                cmd_addr_o    <= (OTHERS => '0');
            ELSE
                s_cmd_valid_r <= '0';  -- pulso de 1 ciclo

                CASE s_rx_state IS

                    WHEN ST_RX_IDLE =>
                        s_rx_active   <= '0';
                        s_oe_n        <= '1';
                        s_rd_n        <= '1';
                        s_adbus_oe_rx <= '1';   -- en idle la FPGA posee el bus (TX)
                        s_abort       <= '0';
                        IF rxf_n_i = '0' THEN
                            s_rx_active <= '1';
                            s_rx_state  <= ST_RX_PRE;
                        END IF;

                    -- La FPGA pide soltar el bus. OE#/RD# siguen en alto.
                    WHEN ST_RX_PRE =>
                        s_adbus_oe_rx <= '0';
                        s_oe_n        <= '1';
                        s_rd_n        <= '1';
                        s_rx_state    <= ST_RX_PRE2;

                    -- Dead-cycle: deja que s_adbus_oe_q (registrado) llegue a
                    -- '0' antes de bajar OE#.
                    WHEN ST_RX_PRE2 =>
                        s_rx_state <= ST_RX_OE;

                    -- OE#='0': el FT232H toma el bus y conduce byte[0].
                    WHEN ST_RX_OE =>
                        s_oe_n     <= '0';
                        s_rx_state <= ST_RX_OE2;

                    -- RD#='0': se cumple "OE# >= 1 ciclo antes de RD#".
                    WHEN ST_RX_OE2 =>
                        s_rd_n     <= '0';
                        s_rx_state <= ST_RD0;

                    -- RD0: rd_n recien a '0'. El FT232H presenta byte[0] pero el
                    -- dato de lectura llega t5 (~9 ns) despues del flanco y, con
                    -- la insercion de reloj, se captura un ciclo mas tarde:
                    -- pipeline -> NO leer aqui (esperar 1 ciclo).
                    WHEN ST_RD0 =>
                        s_rx_state <= ST_RD1;

                    -- RD1: byte[0] = SYNC ya estable en adbus_i.
                    WHEN ST_RD1 =>
                        IF adbus_i = c_CMD_SYNC THEN
                            s_rx_state <= ST_RD2;
                        ELSE
                            -- SYNC incorrecto: abortar limpio.
                            s_abort    <= '1';
                            s_rd_n     <= '1';
                            s_oe_n     <= '1';
                            s_rx_state <= ST_RX_RELEASE;
                        END IF;

                    -- RD2: byte[1] = CMD. Latchear tipo y detectar I2C.
                    WHEN ST_RD2 =>
                        s_cmd_type <= adbus_i;
                        IF adbus_i = c_CMD_I2C THEN
                            s_is_i2c <= '1';
                        ELSE
                            s_is_i2c <= '0';
                        END IF;
                        s_rx_state <= ST_RD3;

                    -- RD3: byte[2] = DATA_H (gral) / PAGE (I2C).
                    WHEN ST_RD3 =>
                        IF s_is_i2c = '1' THEN
                            s_cmd_page <= adbus_i(0);
                        ELSE
                            s_cmd_dh <= adbus_i;
                        END IF;
                        s_rx_state <= ST_RD4;

                    -- RD4: byte[3] = DATA_L (gral, ULTIMO) / ADDR (I2C).
                    WHEN ST_RD4 =>
                        IF s_is_i2c = '1' THEN
                            s_cmd_addr <= adbus_i;
                            s_rx_state <= ST_RD5;
                        ELSE
                            s_cmd_dl   <= adbus_i;
                            -- ultimo byte: soltar RD#/OE# (FPGA aun NO conduce)
                            s_rd_n     <= '1';
                            s_oe_n     <= '1';
                            s_rx_state <= ST_RX_RELEASE;
                        END IF;

                    -- RD5: byte[4] = DATA_H (I2C).
                    WHEN ST_RD5 =>
                        s_cmd_dh   <= adbus_i;
                        s_rx_state <= ST_RD6;

                    -- RD6: byte[5] = DATA_L (I2C, ULTIMO).
                    WHEN ST_RD6 =>
                        s_cmd_dl   <= adbus_i;
                        s_rd_n     <= '1';
                        s_oe_n     <= '1';
                        s_rx_state <= ST_RX_RELEASE;

                    -- El FT232H ya solto el bus (OE#='1' un ciclo). Ahora la
                    -- FPGA puede volver a conducir => sin contienda.
                    WHEN ST_RX_RELEASE =>
                        s_adbus_oe_rx <= '1';
                        s_rx_state    <= ST_RX_RELEASE2;

                    WHEN ST_RX_RELEASE2 =>
                        IF s_abort = '1' THEN
                            s_rx_active <= '0';
                            s_rx_state  <= ST_RX_IDLE;
                        ELSE
                            s_rx_state  <= ST_RX_EXEC;
                        END IF;

                    WHEN ST_RX_EXEC =>
                        s_cmd_valid_r <= '1';
                        cmd_type_o    <= s_cmd_type;
                        cmd_data_o    <= s_cmd_dh & s_cmd_dl;
                        cmd_page_o    <= s_cmd_page;
                        cmd_addr_o    <= s_cmd_addr;
                        s_rx_active   <= '0';
                        s_rx_state    <= ST_RX_IDLE;

                    WHEN OTHERS =>
                        s_rx_active <= '0';
                        s_rx_state  <= ST_RX_IDLE;

                END CASE;
            END IF;
        END IF;
    END PROCESS p_rx;

    ---------------------------------------------------------------------------
    -- p_adbus_t: registra el tristate del bus, un FF por bit, en polaridad
    -- IOBUF.T ('0'=conduce, '1'=Hi-Z). Durante RX manda s_adbus_oe_rx; en
    -- idle/TX manda s_adbus_oe. La inversion (drive-enable -> T) queda en el
    -- lado D del FF (combinacional ANTES del registro), por lo que el lado Q
    -- va directo a OBUFT.T y empaqueta en el IOB.
    -- El ciclo extra de latencia se compensa con ST_RX_PRE2.
    ---------------------------------------------------------------------------
    p_adbus_t : PROCESS(clk_i)
        VARIABLE v_drive : STD_LOGIC;  -- '1' = la FPGA conduce
    BEGIN
        IF rising_edge(clk_i) THEN
            IF reset_i = '1' THEN
                s_adbus_t <= (OTHERS => '0');   -- conduce en reset (OE# alto)
            ELSE
                IF s_rx_active = '1' THEN
                    v_drive := s_adbus_oe_rx;
                ELSE
                    v_drive := s_adbus_oe;
                END IF;
                s_adbus_t <= (OTHERS => NOT v_drive);
            END IF;
        END IF;
    END PROCESS p_adbus_t;

END ARCHITECTURE rtl;
