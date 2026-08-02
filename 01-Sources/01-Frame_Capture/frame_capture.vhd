--! \file frame_capture.vhd
--! \brief Capturador de frames para el sensor MT9V111.
--!
--! Escribe un marcador de inicio de frame (4 bytes: 0xAA 0x55 0xAA 0x55) seguido
--! de los píxeles Y (luminancia) de cada línea, descartando los bytes de croma.
--!
--! Sustituciones en datos de imagen para evitar falsos positivos con el marcador:
--!   0xFF → 0xFE
--!   0x00 → 0x01
--!   0xAA → 0xAB
--!   0x55 → 0x56

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

LIBRARY work;
USE work.config_pkg.ALL;

--! \brief Frame Capture: interfaz con la imagen y con la fifo de salida
--! \fsm_show_actions
ENTITY frame_capture IS
    GENERIC (
        g_H_RES      : INTEGER := c_MT9V111_H_RES;     --! Resolución horizontal en píxeles del sensor MT9V111
        g_V_RES      : INTEGER := c_MT9V111_V_RES;     --! Resolución vertical en líneas del sensor MT9V111
        g_CAM_FPS    : INTEGER := c_MT9V111_FPS;       --! FPS que genera la cámara (según MCLK y registros del sensor)
        g_TARGET_FPS : INTEGER := c_MT9V111_TARGET_FPS --! FPS que se desean capturar (≤ g_CAM_FPS)
    );
    PORT (
        pixclk_i     : IN  STD_LOGIC;                      --! Reloj de píxel del sensor MT9V111
        reset_i      : IN  STD_LOGIC;                      --! Reset síncrono activo alto (dominio pixclk)
        fvalid_i     : IN  STD_LOGIC;                      --! Frame valid: '1' durante la transmisión de un frame
        lvalid_i     : IN  STD_LOGIC;                      --! Line valid: '1' durante la transmisión de una línea
        data_i       : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);   --! Byte de datos del sensor (YCbCr intercalado)
        capture_en_i : IN  STD_LOGIC;                      --! Habilitación de captura; debe estar activo antes del inicio del frame
        fifo_data_o  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);   --! Byte a escribir en la FIFO asíncrona
        fifo_wr_o    : OUT STD_LOGIC;                      --! Habilitación de escritura en la FIFO (1 ciclo por byte)
        fifo_full_i  : IN  STD_LOGIC;                      --! FIFO llena; si sube durante captura se activa overflow_o
        frame_done_o : OUT STD_LOGIC;                      --! Pulso de 1 ciclo al completar el frame
        overflow_o   : OUT STD_LOGIC                       --! '1' si la FIFO se llenó durante la captura; frame corrupto
    );
END ENTITY frame_capture;

ARCHITECTURE rtl of frame_capture IS
    TYPE t_cap_state IS (
        ST_IDLE,              --! Esperando capture_en_i activo
        ST_WAIT_FRAME_START,  --! Esperando flanco de subida de fvalid_i
        ST_MARKER_0,          --! Escribiendo marcador byte 0: c_FRAME_MARKER_0
        ST_MARKER_1,          --! Escribiendo marcador byte 1: c_FRAME_MARKER_1
        ST_MARKER_2,          --! Escribiendo marcador byte 2: c_FRAME_MARKER_2
        ST_MARKER_3,          --! Escribiendo marcador byte 3: c_FRAME_MARKER_3
        ST_WAIT_LINE,         --! Esperando inicio de línea (lvalid_i='1') o fin de frame
        ST_CAPTURE,           --! Capturando píxeles Y de la línea activa
        ST_LINE_END,          --! Línea completada; incrementar s_row_cnt
        ST_FRAME_END,         --! Frame completado; emitir frame_done_o
        ST_SKIP_FRAME         --! Frame ignorado por decimación; esperar fin de fvalid
    );

    SIGNAL s_state : t_cap_state := ST_IDLE;  --! Estado actual de la FSM de captura

    SIGNAL s_byte_cnt : unsigned(10 DOWNTO 0)        := (OTHERS => '0'); --! Contador de bytes recibidos en la línea (par=Y, impar=croma)
    SIGNAL s_col_cnt  : INTEGER RANGE 0 TO g_H_RES-1 := 0;               --! Columna actual dentro de la línea
    SIGNAL s_row_cnt  : INTEGER RANGE 0 TO g_V_RES-1 := 0;               --! Fila actual dentro del frame
    SIGNAL s_lvalid_r : STD_LOGIC                    := '0';             --! Registro de lvalid del ciclo anterior para detectar flanco de subida

    CONSTANT c_FRAME_DIV : INTEGER := g_CAM_FPS / g_TARGET_FPS;  --! Capturar 1 de cada c_FRAME_DIV frames

    SIGNAL s_frame_div_cnt : INTEGER RANGE 0 TO c_FRAME_DIV - 1 := 0;   --! Contador de decimación de frames
    SIGNAL overflow_r      : STD_LOGIC                          := '0'; --! Registro de overflow; se mantiene hasta el siguiente ST_IDLE
    SIGNAL frame_done_r    : STD_LOGIC                          := '0'; --! Registro de frame_done; pulso de 1 ciclo

    SIGNAL rst_pixclk_2ff: STD_LOGIC_VECTOR(1 DOWNTO 0) :=(OTHERS => '1');
    SIGNAL rst_pixclk    : STD_LOGIC;

BEGIN

    frame_done_o <= frame_done_r;
    overflow_o   <= overflow_r;

    p_reset_sync: PROCESS(pixclk_i, reset_i)
    BEGIN
        IF reset_i = '1' THEN
            rst_pixclk_2ff <= (OTHERS => '1');
        ELSIF rising_edge(pixclk_i) THEN
            rst_pixclk_2ff(0) <= '0';
            rst_pixclk_2ff(1) <= rst_pixclk_2ff(0);
        END IF;
    END PROCESS p_reset_sync;
    rst_pixclk <= rst_pixclk_2ff(1);


    --! \brief FSM de captura de frame — dominio pixclk_i
    p_capture : PROCESS(pixclk_i)
    BEGIN
        -- /todo Reset aquí no se cumple porque pixclk_i es una señal post-reset 
        IF rising_edge(pixclk_i) THEN
            IF rst_pixclk = '1' THEN
                s_state         <= ST_IDLE;
                s_byte_cnt      <= (OTHERS => '0');
                s_col_cnt       <= 0;
                s_row_cnt       <= 0;
                s_frame_div_cnt <= 0;
                fifo_data_o     <= (OTHERS => '0');
                fifo_wr_o       <= '0';
                overflow_r      <= '0';
                frame_done_r    <= '0';
                s_lvalid_r      <= '0';
            ELSE
                fifo_wr_o    <= '0';
                frame_done_r <= '0';
                s_lvalid_r   <= lvalid_i;  --! Registrar lvalid para detectar flanco de subida

                CASE s_state IS

                    WHEN ST_IDLE =>
                        s_byte_cnt <= (OTHERS => '0');
                        s_col_cnt  <= 0;
                        s_row_cnt  <= 0;
                        overflow_r <= '0';
                        IF capture_en_i = '1' THEN
                            IF fvalid_i = '0' THEN
                                s_state <= ST_WAIT_FRAME_START;
                            END IF;
                        END IF;

                    WHEN ST_WAIT_FRAME_START =>
                        IF capture_en_i = '0' THEN
                            s_state <= ST_IDLE;
                        ELSIF fvalid_i = '1' THEN
                            IF s_frame_div_cnt = 0 THEN
                                s_frame_div_cnt <= c_FRAME_DIV - 1;  --! Capturar este frame
                                s_state         <= ST_MARKER_0;
                            ELSE
                                s_frame_div_cnt <= s_frame_div_cnt - 1;  --! Saltar este frame
                                s_state         <= ST_SKIP_FRAME;
                            END IF;
                        END IF;

                    -----------------------------------------------------------
                    -- Marcador de inicio de frame
                    -----------------------------------------------------------
                    WHEN ST_MARKER_0 =>
                        IF fifo_full_i = '0' THEN
                            fifo_data_o <= c_FRAME_MARKER_0;
                            fifo_wr_o   <= '1';
                            s_state     <= ST_MARKER_1;
                        END IF;

                    WHEN ST_MARKER_1 =>
                        IF fifo_full_i = '0' THEN
                            fifo_data_o <= c_FRAME_MARKER_1;
                            fifo_wr_o   <= '1';
                            s_state     <= ST_MARKER_2;
                        END IF;

                    WHEN ST_MARKER_2 =>
                        IF fifo_full_i = '0' THEN
                            fifo_data_o <= c_FRAME_MARKER_2;
                            fifo_wr_o   <= '1';
                            s_state     <= ST_MARKER_3;
                        END IF;

                    WHEN ST_MARKER_3 =>
                        IF fifo_full_i = '0' THEN
                            fifo_data_o <= c_FRAME_MARKER_3;
                            fifo_wr_o   <= '1';
                            s_state     <= ST_WAIT_LINE;
                        END IF;

                    WHEN ST_WAIT_LINE =>
                        s_byte_cnt <= (OTHERS => '0');
                        s_col_cnt  <= 0;
                        IF fvalid_i = '0' THEN
                            s_state <= ST_FRAME_END;
                        ELSIF lvalid_i = '1' and s_lvalid_r = '0' THEN  --! Flanco de subida
                            s_state <= ST_CAPTURE;
                        END IF;

                    -----------------------------------------------------------
                    -- Captura con sustituciones para evitar falsos positivos
                    -- s_byte_cnt(0)='1' → byte Y (capturar)
                    -- s_byte_cnt(0)='0' → byte croma (descartar)
                    -----------------------------------------------------------
                    WHEN ST_CAPTURE =>
                        IF lvalid_i = '0' THEN
                            s_state <= ST_LINE_END;
                        ELSE
                            s_byte_cnt <= s_byte_cnt + 1;

                            IF s_byte_cnt(0) = '0' THEN
                                IF fifo_full_i = '0' THEN
                                    IF    data_i = c_PROTO_RESERVED_FF THEN fifo_data_o <= c_PROTO_REPLACE_FF;
                                    ELSIF data_i = c_PROTO_RESERVED_00 THEN fifo_data_o <= c_PROTO_REPLACE_00;
                                    ELSIF data_i = c_PROTO_RESERVED_AA THEN fifo_data_o <= c_PROTO_REPLACE_AA;
                                    ELSIF data_i = c_PROTO_RESERVED_55 THEN fifo_data_o <= c_PROTO_REPLACE_55;
                                    ELSE                                     fifo_data_o <= data_i;
                                    END IF;
                                    fifo_wr_o <= '1';
                                ELSE
                                    overflow_r <= '1';
                                END IF;

                                IF s_col_cnt = g_H_RES - 1 THEN
                                    s_col_cnt <= 0;
                                ELSE
                                    s_col_cnt <= s_col_cnt + 1;
                                END IF;
                            END IF;
                        END IF;

                    WHEN ST_LINE_END =>
                        s_byte_cnt <= (OTHERS => '0');
                        s_col_cnt  <= 0;
                        s_lvalid_r <= '0';  --! Forzar reset para garantizar detección de flanco en siguiente línea
                        IF s_row_cnt = g_V_RES - 1 THEN
                            s_row_cnt <= 0;
                        ELSE
                            s_row_cnt <= s_row_cnt + 1;
                        END IF;
                        IF fvalid_i = '0' THEN
                            s_state <= ST_FRAME_END;
                        ELSE
                            s_state <= ST_WAIT_LINE;
                        END IF;

                    WHEN ST_FRAME_END =>
                        frame_done_r <= '1';
                        s_state      <= ST_IDLE;

                    --! Esperar fin de frame ignorado (fvalid baja)
                    WHEN ST_SKIP_FRAME =>
                        IF fvalid_i = '0' THEN
                            s_state <= ST_WAIT_FRAME_START;
                        END IF;

                    WHEN OTHERS =>
                        s_state <= ST_IDLE;

                END CASE;
            END IF;
        END IF;
    END PROCESS p_capture;

END ARCHITECTURE rtl;