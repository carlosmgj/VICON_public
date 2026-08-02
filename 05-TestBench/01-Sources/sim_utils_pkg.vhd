--! \file sim_utils_pkg.vhd
--! \brief Paquete de utilidades para simulación VHDL.
--!
--! Proporciona:
--!   - Constantes globales de simulación
--!   - Constantes reducidas para acelerar la simulación
--!   - Funciones de conversión de tipos para logging
--!   - Procedimiento de log a fichero con timestamp
--!   - Procedimiento de verificación con scoreboard y reporte a fichero
--! \author Carlos Manuel Gomez Jimenez

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE std.textio.ALL;

PACKAGE sim_utils_pkg IS

    ---------------------------------------------------------------------------
    -- Constantes globales de simulación
    ---------------------------------------------------------------------------
    CONSTANT c_CLK_PERIOD       : TIME    := 10 ns;  --! Periodo del reloj de sistema en simulación (100 MHz)
    CONSTANT c_TXE_READY_CYCLES : INTEGER := 200;
    CONSTANT c_TXE_BUSY_CYCLES  : INTEGER := 800;

    ---------------------------------------------------------------------------
    -- Funciones de conversión para logging
    ---------------------------------------------------------------------------

    --! \brief Convierte un STD_LOGIC_VECTOR a STRING de '0'/'1'/'X'
    FUNCTION vec_to_str(vec : STD_LOGIC_VECTOR) RETURN STRING;

    --! \brief Convierte un INTEGER a STRING hexadecimal de anchura fija
    --! \param val   Valor a convertir
    --! \param WIDTH Número de dígitos hex del resultado (default: 2)
    FUNCTION int_to_hex_str(val : INTEGER; WIDTH : INTEGER := 2) RETURN STRING;

    ---------------------------------------------------------------------------
    -- Procedimientos de simulación
    ---------------------------------------------------------------------------

    --! \brief Escribe una línea en un fichero de log con timestamp y prefijo INFO/ERROR
    --! \param file_name Nombre del fichero de salida
    --! \param message   Mensaje a escribir
    --! \param is_error  Si true, prefijo "ERROR:"; si FALSE, prefijo "INFO :"
    PROCEDURE log_to_file(
        CONSTANT file_name : IN STRING;
        CONSTANT message   : IN STRING;
        CONSTANT is_error  : IN boolean := FALSE
    );

    --! \brief Compara actual con expected; registra resultado en scoreboard y fichero
    --! \param actual    Valor obtenido de la simulación
    --! \param expected  Valor esperado
    --! \param msg_tag   Etiqueta identificativa del punto de verificación
    --! \param error_cnt Contador de errores acumulados (INOUT)
    --! \param file_name Fichero de reporte (default: "reporte_final_1.txt")
    PROCEDURE check_value(
        CONSTANT actual    : IN    STD_LOGIC_VECTOR;
        CONSTANT expected  : IN    STD_LOGIC_VECTOR;
        CONSTANT msg_tag   : IN    STRING;
        VARIABLE error_cnt : INOUT INTEGER;
        CONSTANT file_name : IN    STRING := "reporte_final_1.txt"
    );

END PACKAGE sim_utils_pkg;

PACKAGE body sim_utils_pkg IS

    ---------------------------------------------------------------------------
    FUNCTION vec_to_str(vec : STD_LOGIC_VECTOR) RETURN STRING IS
        VARIABLE v_res : STRING(1 TO vec'length);
    BEGIN
        FOR i IN 0 TO vec'length - 1 LOOP
            IF    vec(vec'high - i) = '1' THEN v_res(i + 1) := '1';
            ELSIF vec(vec'high - i) = '0' THEN v_res(i + 1) := '0';
            ELSE                               v_res(i + 1) := 'X';
            END IF;
        END LOOP;
        RETURN v_res;
    END FUNCTION vec_to_str;

    ---------------------------------------------------------------------------
    FUNCTION int_to_hex_str(val : INTEGER; WIDTH : INTEGER := 2) RETURN STRING IS
        CONSTANT c_HEX_CHARS : STRING(1 TO 16)                  := "0123456789ABCDEF";
        VARIABLE v_temp      : STD_LOGIC_VECTOR(WIDTH * 4 - 1 DOWNTO 0);
        VARIABLE v_res       : STRING(1 TO WIDTH);
        VARIABLE v_nibble    : INTEGER;
    BEGIN
        v_temp := STD_LOGIC_VECTOR(to_unsigned(val, WIDTH * 4));
        FOR i IN 0 TO WIDTH - 1 LOOP
            v_nibble         := to_integer(unsigned(v_temp((i + 1) * 4 - 1 DOWNTO i * 4)));
            v_res(WIDTH - i) := c_HEX_CHARS(v_nibble + 1);
        END LOOP;
        RETURN v_res;
    END FUNCTION int_to_hex_str;

    ---------------------------------------------------------------------------
    PROCEDURE log_to_file(
        CONSTANT file_name : IN STRING;
        CONSTANT message   : IN STRING;
        CONSTANT is_error  : IN boolean := FALSE
    ) IS
        FILE     f_out   : text;
        VARIABLE v_line  : line;
        VARIABLE v_prefix : STRING(1 TO 7);
    BEGIN
        IF is_error THEN
            v_prefix := "ERROR :";
        ELSE
            v_prefix := "INFO  :";
        END IF;
        file_open(f_out, file_name, append_mode);
        write(v_line, "[" & TIME'image(now) & "] - " & v_prefix & " " & message);
        writeline(f_out, v_line);
        file_close(f_out);
    END PROCEDURE log_to_file;

    ---------------------------------------------------------------------------
    PROCEDURE check_value(
        CONSTANT actual    : IN    STD_LOGIC_VECTOR;
        CONSTANT expected  : IN    STD_LOGIC_VECTOR;
        CONSTANT msg_tag   : IN    STRING;
        VARIABLE error_cnt : INOUT INTEGER;
        CONSTANT file_name : IN    STRING := "reporte_final_1.txt"
    ) IS
    BEGIN
        IF actual = expected THEN
            log_to_file(file_name, msg_tag & " OK    | Val: " & vec_to_str(actual), FALSE);
            REPORT "[SIM] " & msg_tag & " OK";
        ELSE
            error_cnt := error_cnt + 1;
            log_to_file(file_name,
                msg_tag & " FALLO | Exp: " & vec_to_str(expected) &
                          "  Act: " & vec_to_str(actual), true);
            REPORT "[SIM] " & msg_tag & " FAIL" SEVERITY error;
        END IF;
    END PROCEDURE check_value;

END PACKAGE body sim_utils_pkg;
