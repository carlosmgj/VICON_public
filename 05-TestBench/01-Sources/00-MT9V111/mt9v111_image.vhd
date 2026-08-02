--! \file mt9v111_image.vhd
--! \brief Simulador de cámara MT9V111 para test del pipeline de captura.
--!
--! Genera señales de cámara sintéticas con un patrón conocido:
--!   - fvalid_o, lvalid_o con timing correcto
--!   - data_o en formato YCbCr 4:2:2 igual que el MT9V111 real
--!
--! Orden de bytes según datasheet MT9V111 Table 3 (default, no swap):
--!   Byte 0: Cb_i   = 0x80  (croma azul,  descartar)
--!   Byte 1: Y_i    = col/2 (luma píxel i, capturar)
--!   Byte 2: Cr_i   = 0x80  (croma rojo,  descartar)
--!   Byte 3: Y_i+1  = col/2 (luma píxel i+1, capturar)
--!
--! El patrón de imagen generado es:
--!   - Cada píxel Y = número de píxel en la línea (0..g_H_RES-1, wrapping a 8 bits)
--!   - Cada línea es un gradiente horizontal idéntico
--!   - Si frame_capture funciona correctamente, Python debe ver un gradiente
--!     horizontal uniforme sin desplazamiento entre líneas
--! \author Carlos Manuel Gomez Jimenez

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

LIBRARY work;
USE work.config_pkg.ALL;

--! \brief Simulador de cámara MT9V111
--! \fsm_show_actions
ENTITY mt9v111_image IS
    GENERIC (
        g_H_RES  : INTEGER := c_MT9V111_H_RES;  --! Resolución horizontal en píxeles
        g_V_RES  : INTEGER := c_MT9V111_V_RES;  --! Resolución vertical en líneas
        g_HBLANK : INTEGER := 100;               --! Ciclos de blanking horizontal entre líneas
        g_VBLANK : INTEGER := 1000              --! Ciclos de blanking vertical entre frames
    );
    PORT (
        clkin_i  : IN  std_logic;                     --! MCLK recibido del TOP (= mt_clk_o)
        pixclk_o : OUT std_logic;                     --! Reloj de píxel generado por el sensor (dominio del sensor)
        reset_i  : IN  std_logic;                     --! Reset síncrono activo alto
        fvalid_o : OUT std_logic;                     --! Frame valid: '1' durante la transmisión de un frame
        lvalid_o : OUT std_logic;                     --! Line valid: '1' durante la transmisión de una línea
        data_o   : OUT std_logic_vector(7 DOWNTO 0)   --! Byte de datos sintético (YCbCr 4:2:2)
    );
END ENTITY mt9v111_image;

ARCHITECTURE rtl OF mt9v111_image IS

    ---------------------------------------------------------------------------
    -- Constantes de timing
    ---------------------------------------------------------------------------
    CONSTANT c_P2             : INTEGER := 14;           --! Frame END Blanking: ciclos entre LVALID↓ y FVALID↓ (datasheet fijo)
    CONSTANT c_BYTES_PER_LINE : INTEGER := g_H_RES * 2;  --! Bytes activos por línea: 2 bytes/px × g_H_RES px

    ---------------------------------------------------------------------------
    -- FSM
    ---------------------------------------------------------------------------
    TYPE t_state IS (
        ST_VBLANK,     --! Blanking vertical: fvalid_o='0', esperando inicio de frame
        ST_HBLANK,     --! Blanking horizontal: fvalid_o='1', lvalid_o='0', esperando inicio de línea
        ST_ACTIVE,     --! Línea activa: fvalid_o='1', lvalid_o='1', generando datos YCbCr
        ST_FRAME_END   --! P2: 14 ciclos entre último LVALID↓ y FVALID↓
    );

    SIGNAL s_state : t_state := ST_VBLANK;  --! Estado actual de la FSM

    ---------------------------------------------------------------------------
    -- s_col_cnt cuenta bytes (4 bytes por píxel):
    --   s_col_cnt mod 4 = 0 → Cb
    --   s_col_cnt mod 4 = 1 → Y_i
    --   s_col_cnt mod 4 = 2 → Cr
    --   s_col_cnt mod 4 = 3 → Y_{i+1}
    -- Rango: 0 .. g_H_RES*2-1 (2 bytes/px × g_H_RES px)
    ---------------------------------------------------------------------------
    SIGNAL s_col_cnt   : UNSIGNED(11 DOWNTO 0)           := (OTHERS => '0');  --! Contador de bytes en la línea (4 bytes por par de píxeles)
    SIGNAL s_row_cnt   : INTEGER RANGE 0 TO g_V_RES  - 1 := 0;                --! Contador de líneas dentro del frame
    SIGNAL s_blank_cnt : INTEGER := 0;  --! Contador de ciclos de blanking (usado para HBLANK y VBLANK)

    SIGNAL fvalid_r : std_logic                    := '0';              --! Registro de frame valid
    SIGNAL lvalid_r : std_logic                    := '0';              --! Registro de line valid
    SIGNAL data_r   : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0'); --! Registro de dato de salida

    ---------------------------------------------------------------------------
    -- Número de píxel correspondiente al byte actual:
    --   píxel_num = s_col_cnt / 2  (cada par Cb/Y o Cr/Y comparte índice de píxel)
    ---------------------------------------------------------------------------
    SIGNAL s_pix_num : UNSIGNED(10 DOWNTO 0);  --! Índice del píxel en la línea (0..g_H_RES-1)

BEGIN

    pixclk_o <= clkin_i;  -- el sensor pasa MCLK como PIXCLK (mismo periodo, sin delay en sim)

    fvalid_o <= fvalid_r;
    lvalid_o <= lvalid_r;
    data_o   <= data_r;

    -- El número de píxel es s_col_cnt >> 1 (2 bytes comparten el mismo píxel)
    s_pix_num <= s_col_cnt(11 DOWNTO 1);

    --! \brief FSM generadora de timing de cámara — dominio pixclk_o
    p_sim : PROCESS(clkin_i)
    BEGIN
        IF rising_edge(clkin_i) THEN
            IF reset_i = '1' THEN
                s_state     <= ST_VBLANK;
                s_col_cnt   <= (OTHERS => '0');
                s_row_cnt   <= 0;
                s_blank_cnt <= 0;
                fvalid_r    <= '0';
                lvalid_r    <= '0';
                data_r      <= (OTHERS => '0');
            ELSE
                CASE s_state IS

                    WHEN ST_VBLANK =>
                        fvalid_r <= '0';
                        lvalid_r <= '0';
                        data_r   <= (OTHERS => '0');
                        IF s_blank_cnt = g_VBLANK - 1 THEN
                            s_blank_cnt <= 0;
                            s_row_cnt   <= 0;
                            s_state     <= ST_HBLANK;
                        ELSE
                            s_blank_cnt <= s_blank_cnt + 1;
                        END IF;

                    WHEN ST_HBLANK =>
                        fvalid_r <= '1';
                        lvalid_r <= '0';
                        data_r   <= (OTHERS => '0');
                        IF s_blank_cnt = g_HBLANK - 1 THEN
                            s_blank_cnt <= 0;
                            s_col_cnt   <= (OTHERS => '0');
                            s_state     <= ST_ACTIVE;
                        ELSE
                            s_blank_cnt <= s_blank_cnt + 1;
                        END IF;

                    -----------------------------------------------------------
                    -- Línea activa — formato YCbCr 4:2:2 según MT9V111 datasheet:
                    --   s_col_cnt(1:0) = "00" → Cb   = 0x80  (croma azul)
                    --   s_col_cnt(1:0) = "01" → Y_i  = píxel (luma par)
                    --   s_col_cnt(1:0) = "10" → Cr   = 0x80  (croma rojo)
                    --   s_col_cnt(1:0) = "11" → Y_i+1= píxel (luma impar)
                    -- 4 bytes por cada par de píxeles → g_H_RES*4 bytes por línea
                    -----------------------------------------------------------
                    WHEN ST_ACTIVE =>
                        fvalid_r <= '1';
                        lvalid_r <= '1';

                        CASE s_col_cnt(1 DOWNTO 0) IS
                            WHEN "00"   => data_r <= x"80";  -- Cb
                            WHEN "10"   => data_r <= x"80";  -- Cr
                            WHEN OTHERS =>                   -- "01" Y_i, "11" Y_{i+1}
                                data_r <= std_logic_vector(s_pix_num(7 DOWNTO 0));
                        END CASE;

                        IF s_col_cnt = to_unsigned(g_H_RES * 2 - 1, 12) THEN
                            s_col_cnt <= (OTHERS => '0');
                            IF s_row_cnt = g_V_RES - 1 THEN
                                s_row_cnt <= 0;
                                s_state   <= ST_FRAME_END;
                            ELSE
                                s_row_cnt <= s_row_cnt + 1;
                                s_state   <= ST_HBLANK;
                            END IF;
                        ELSE
                            s_col_cnt <= s_col_cnt + 1;
                        END IF;

                    WHEN ST_FRAME_END =>
                        fvalid_r <= '1';   -- FVALID todavía alto durante P2
                        lvalid_r <= '0';
                        data_r   <= (OTHERS => '0');
                        IF s_blank_cnt = c_P2 - 1 THEN
                            s_blank_cnt <= 0;
                            fvalid_r    <= '0';   -- FVALID baja al final de P2
                            s_state     <= ST_VBLANK;
                        ELSE
                            s_blank_cnt <= s_blank_cnt + 1;
                        END IF;

                    WHEN OTHERS =>
                        s_state <= ST_VBLANK;
                    
                END CASE;
            END IF;
        END IF;
    END PROCESS p_sim;

END ARCHITECTURE rtl;