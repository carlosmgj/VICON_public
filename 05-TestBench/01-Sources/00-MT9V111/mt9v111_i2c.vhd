--! \file mt9v111_i2c.vhd
--! \brief Agente de simulacion I2C esclavo del MT9V111.
--!
--! Protocolo MT9V111 segun datasheet:
--!
--!   WRITE (16-bit):
--!     START -> ADDR_W -> REG_ADDR -> DATA_H -> DATA_L -> STOP
--!
--!   READ (16-bit) con Repeated START:
--!     START -> ADDR_W -> REG_ADDR -> RSTART -> ADDR_R -> DATA_H -> DATA_L -> NACK -> STOP
--!
--!   READ (16-bit) con dos transacciones separadas:
--!     START -> ADDR_W -> REG_ADDR -> STOP
--!     START -> ADDR_R -> DATA_H -> DATA_L -> NACK -> STOP
--!
--! Page select: escritura en reg 0x01
--!   0x0004 -> Core,  0x0001 -> IFP
--!
--! \note Solo valido en simulacion. No sintetizable.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY mt9v111_i2c IS
    GENERIC (
        g_I2C_ADDR : STD_LOGIC_VECTOR(6 DOWNTO 0) := "1011100"
    );
    PORT (
        scl_i  : IN    STD_LOGIC;
        sda_io : INOUT STD_LOGIC
    );
END ENTITY mt9v111_i2c;

ARCHITECTURE sim OF mt9v111_i2c IS

    TYPE t_reg_map IS ARRAY (0 TO 255) OF STD_LOGIC_VECTOR(15 DOWNTO 0);

    SIGNAL s_regs_core : t_reg_map := (
        16#36# => x"823A",
        16#FF# => x"823A",
        16#0D# => x"0008",
        OTHERS => x"CACA"
    );

    SIGNAL s_regs_ifp : t_reg_map := (
        16#01# => x"0001",
        OTHERS => x"0FE0"
    );

    SIGNAL s_current_page : STD_LOGIC          := '0';
    SIGNAL s_reg_addr     : integer RANGE 0 TO 255 := 0;
    SIGNAL s_debug_state  : string(1 TO 24)    := (OTHERS => ' ');

BEGIN

    p_i2c_slave : PROCESS
        VARIABLE v_addr_byte    : STD_LOGIC_VECTOR(7 DOWNTO 0);
        VARIABLE v_data_h       : STD_LOGIC_VECTOR(7 DOWNTO 0);
        VARIABLE v_data_l       : STD_LOGIC_VECTOR(7 DOWNTO 0);
        VARIABLE v_data_16      : STD_LOGIC_VECTOR(15 DOWNTO 0);
        VARIABLE v_bit          : STD_LOGIC;
        VARIABLE v_reg_addr     : integer RANGE 0 TO 255 := 0;
        VARIABLE v_current_page : STD_LOGIC := '0';
        VARIABLE v_rstart       : boolean   := FALSE;
        VARIABLE v_stop         : boolean   := FALSE;

        ---------------------------------------------------------------------------
        -- Espera START o Repeated START: SDA baja con SCL alto
        ---------------------------------------------------------------------------
        PROCEDURE wait_start IS
        BEGIN
            s_debug_state <= "WAIT_START              ";
            LOOP
                WAIT UNTIL To_X01(sda_io) = '0';
                EXIT WHEN To_X01(scl_i) = '1';
            END LOOP;
            s_debug_state <= "START_DETECTED          ";
        END PROCEDURE;

        ---------------------------------------------------------------------------
        -- Lee 8 bits MSB primero.
        -- Detecta Repeated START (SDA baja con SCL alto) o STOP (SDA sube con SCL alto)
        -- durante la lectura y los reporta en v_rstart/v_stop.
        -- Si se detecta, el byte leido hasta ese momento es invalido.
        ---------------------------------------------------------------------------
        PROCEDURE read_byte (
            VARIABLE b       : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
            VARIABLE rstart  : OUT boolean;
            VARIABLE stop    : OUT boolean
        ) IS
            VARIABLE v_b        : STD_LOGIC;
            VARIABLE v_sda_prev : STD_LOGIC;
        BEGIN
            rstart := FALSE;
            stop   := FALSE;
            b      := (OTHERS => '0');

            FOR i IN 7 DOWNTO 0 LOOP
                -- Esperar flanco de subida de SCL
                WAIT UNTIL To_X01(scl_i) = '1';

                -- Guardar SDA al subir SCL
                v_sda_prev := To_X01(sda_io);
                v_b        := v_sda_prev;
                IF v_b = 'X' THEN v_b := '0'; END IF;
                b(i) := v_b;

                -- Mientras SCL esta alto, vigilar cambios de SDA
                -- Un cambio aqui es RSTART (SDA baja) o STOP (SDA sube)
                LOOP
                    WAIT ON scl_i, sda_io;
                    IF To_X01(scl_i) = '0' THEN
                        EXIT;  -- bajada normal de SCL, continuar
                    END IF;
                    -- SCL sigue alto y SDA cambio
                    IF To_X01(sda_io) = '0' AND v_sda_prev /= '0' THEN
                        rstart := TRUE;
                        RETURN;
                    END IF;
                    IF To_X01(sda_io) = '1' AND v_sda_prev /= '1' THEN
                        stop := TRUE;
                        RETURN;
                    END IF;
                    v_sda_prev := To_X01(sda_io);
                END LOOP;

            END LOOP;
        END PROCEDURE;

        ---------------------------------------------------------------------------
        -- Envia ACK: conduce SDA='0' durante el pulso de ACK
        -- Llamar justo despues de read_byte (SCL ya esta bajo)
        ---------------------------------------------------------------------------
        PROCEDURE send_ack IS
        BEGIN
            sda_io <= '0';
            WAIT UNTIL To_X01(scl_i) = '1';
            WAIT UNTIL To_X01(scl_i) = '0';
            sda_io <= 'Z';
        END PROCEDURE;

        ---------------------------------------------------------------------------
        -- Envia un byte MSB primero en modo lectura
        -- Cada bit se pone en SDA en el flanco de bajada de SCL
        ---------------------------------------------------------------------------
        PROCEDURE send_byte (
            constant b : IN STD_LOGIC_VECTOR(7 DOWNTO 0)
        ) IS
        BEGIN
            -- SCL ya esta bajo al entrar: poner bit 7 inmediatamente
            sda_io <= b(7);
            FOR i IN 6 DOWNTO 0 LOOP
                WAIT UNTIL To_X01(scl_i) = '0';
                sda_io <= b(i);
            END LOOP;
            -- Soltar SDA para el ACK/NACK del master
            WAIT UNTIL To_X01(scl_i) = '0';
            sda_io <= 'Z';
        END PROCEDURE;

        ---------------------------------------------------------------------------
        -- Lee el ACK/NACK del master (1 pulso de SCL)
        -- Devuelve '0'=ACK, '1'=NACK
        ---------------------------------------------------------------------------
        PROCEDURE read_mack (VARIABLE mack : OUT STD_LOGIC) IS
        BEGIN
            WAIT UNTIL To_X01(scl_i) = '1';
            mack := To_X01(sda_io);
            IF mack = 'X' THEN mack := '1'; END IF;
            WAIT UNTIL To_X01(scl_i) = '0';
        END PROCEDURE;

        ---------------------------------------------------------------------------
        -- Realiza la transmision de datos en modo lectura
        ---------------------------------------------------------------------------
        PROCEDURE do_read IS
            VARIABLE v_mack : STD_LOGIC;
        BEGIN
            s_debug_state <= "TX_DATA                 ";
            s_reg_addr    <= v_reg_addr;

            IF v_current_page = '0' THEN
                send_byte(s_regs_core(v_reg_addr)(15 DOWNTO 8));
                -- Esperar bajada de SCL tras el ACK del master antes del segundo byte
                WAIT UNTIL To_X01(scl_i) = '0';
                send_byte(s_regs_core(v_reg_addr)(7  DOWNTO 0));
            ELSE
                send_byte(s_regs_ifp(v_reg_addr)(15 DOWNTO 8));
                WAIT UNTIL To_X01(scl_i) = '0';
                send_byte(s_regs_ifp(v_reg_addr)(7  DOWNTO 0));
            END IF;

            read_mack(v_mack);

            IF To_X01(v_mack) = '1' THEN
                s_debug_state <= "READ_DONE_NACK          ";
            ELSE
                s_debug_state <= "READ_DONE_ACK           ";
            END IF;
        END PROCEDURE;

    BEGIN
        sda_io <= 'Z';

        LOOP
            -----------------------------------------------------------------------
            -- Esperar START
            -----------------------------------------------------------------------
            wait_start;

            -----------------------------------------------------------------------
            -- Leer byte de direccion + R/W
            -----------------------------------------------------------------------
            read_byte(v_addr_byte, v_rstart, v_stop);

            IF v_rstart OR v_stop THEN NEXT; END IF;
            IF v_addr_byte(7 DOWNTO 1) /= g_I2C_ADDR THEN NEXT; END IF;

            s_debug_state <= "ADDR_MATCH              ";
            send_ack;

            -----------------------------------------------------------------------
            -- Modo lectura directa (START -> ADDR_R -> DATA)
            -----------------------------------------------------------------------
            IF v_addr_byte(0) = '1' THEN
                do_read;
                NEXT;
            END IF;

            -----------------------------------------------------------------------
            -- Modo escritura: recibir REG_ADDR
            -----------------------------------------------------------------------
            s_debug_state <= "RX_REG_ADDR             ";
            read_byte(v_addr_byte, v_rstart, v_stop);

            IF v_rstart OR v_stop THEN NEXT; END IF;

            v_reg_addr := TO_INTEGER(UNSIGNED(v_addr_byte));
            s_reg_addr <= v_reg_addr;
            send_ack;

            -----------------------------------------------------------------------
            -- Intentar leer DATA_H
            -- Puede llegar: dato normal, Repeated START, o STOP
            -----------------------------------------------------------------------
            s_debug_state <= "RX_DATA_H               ";
            read_byte(v_data_h, v_rstart, v_stop);

            -- STOP: transaccion de solo direccion (para lectura posterior)
            IF v_stop THEN
                s_debug_state <= "ADDR_ONLY_STOP          ";
                NEXT;
            END IF;

            -- Repeated START: cambiar a modo lectura
            IF v_rstart THEN
                s_debug_state <= "RSTART_DETECTED         ";
                -- Leer byte de direccion del Repeated START
                read_byte(v_addr_byte, v_rstart, v_stop);
                IF v_rstart OR v_stop THEN NEXT; END IF;
                IF v_addr_byte(7 DOWNTO 1) /= g_I2C_ADDR THEN NEXT; END IF;
                IF v_addr_byte(0) /= '1' THEN NEXT; END IF;  -- debe ser lectura
                send_ack;
                do_read;
                NEXT;
            END IF;

            -- Dato normal: enviar ACK y leer DATA_L
            send_ack;

            s_debug_state <= "RX_DATA_L               ";
            read_byte(v_data_l, v_rstart, v_stop);
            send_ack;

            v_data_16 := v_data_h & v_data_l;

            -- Page select: reg 0x01
            IF v_reg_addr = 1 THEN
                IF v_data_16 = x"0004" THEN
                    v_current_page := '0';
                    s_current_page <= '0';
                    s_debug_state  <= "PAGE_SEL_CORE           ";
                ELSIF v_data_16 = x"0001" THEN
                    v_current_page := '1';
                    s_current_page <= '1';
                    s_debug_state  <= "PAGE_SEL_IFP            ";
                END IF;
            END IF;

            -- Guardar en banco activo
            IF v_current_page = '0' THEN
                s_regs_core(v_reg_addr) <= v_data_16;
            ELSE
                s_regs_ifp(v_reg_addr) <= v_data_16;
            END IF;

            s_debug_state <= "WRITE_DONE              ";

        END LOOP;

    END PROCESS p_i2c_slave;

END ARCHITECTURE sim;
