--! \file clock_generator.vhd
--! \brief Generador de reloj y reset para simulación.
--! \author Carlos Manuel Gomez Jimenez

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;

LIBRARY work;
USE work.sim_utils_pkg.ALL;

ENTITY clk_reset_gen IS
    GENERIC (
        g_RESET_DURATION : TIME := 100 ns  --! Duración del reset activo al inicio de la simulación
    );
    PORT (
        clk_out   : OUT STD_LOGIC;  --! Reloj 100 MHz generado
        reset_out : OUT STD_LOGIC   --! Reset activo alto; se desactiva tras g_RESET_DURATION
    );
END ENTITY clk_reset_gen;

ARCHITECTURE sim OF clk_reset_gen IS

    SIGNAL s_clk   : STD_LOGIC := '0';  --! Registro interno del reloj
    SIGNAL s_reset : STD_LOGIC := '1';  --! Registro interno del reset (arranca activo)

BEGIN

    clk_out   <= s_clk;
    reset_out <= s_reset;

    --! \brief Generador de reloj — periodo definido por c_CLK_PERIOD de sim_utils_pkg
    p_clk : PROCESS
    BEGIN
        LOOP
            s_clk <= '0';
            WAIT FOR c_CLK_PERIOD / 2;
            s_clk <= '1';
            WAIT FOR c_CLK_PERIOD / 2;
        END LOOP;
    END PROCESS p_clk;

    --! \brief Generador de reset — activo alto durante g_RESET_DURATION
    p_reset : PROCESS
    BEGIN
        s_reset <= '1';
        WAIT FOR g_RESET_DURATION;
        s_reset <= '0';
        WAIT;
    END PROCESS p_reset;

END ARCHITECTURE sim;
