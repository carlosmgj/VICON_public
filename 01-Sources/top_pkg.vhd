--! \file top_pkg.vhd
--! \brief Tipos compartidos del modulo TOP.
--!
--! Separado de config_pkg para no mezclar constantes de sistema
--! con tipos de FSM especificos del TOP.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;

PACKAGE top_pkg IS

    ---------------------------------------------------------------------------
    --! \brief Estados de la FSM principal del TOP.
    ---------------------------------------------------------------------------
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

END PACKAGE top_pkg;
